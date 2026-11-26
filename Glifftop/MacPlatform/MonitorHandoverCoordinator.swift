import AppKit
import GliffInput
import os

/// The pointer handover between a host's monitor windows, app-wide: watches the picture of
/// each live mirror whose window isn't key (`PictureHoverWatcher`), gathers the key window's and
/// the window under the pointer's facts for GliffInput's `MonitorHandover`, keeps its 100 ms
/// timer, and when it says so leaves the entry point with the other window's capture and brings
/// that window in front. Its activation then nudges the host's pointer to the entry point.
final class MonitorHandoverCoordinator {
    static let shared = MonitorHandoverCoordinator()

    private static let logger = Logger(subsystem: "me.cbyrd.Glifftop", category: "handover")

    private let captures = NSHashTable<CaptureController>.weakObjects()
    /// The capture of the key window.
    private weak var key: CaptureController?
    /// A watcher installed, with the capture it reports for.
    private struct Watch {
        let watcher: PictureHoverWatcher
        weak var capture: CaptureController?
    }

    /// The watchers installed, by their video view.
    private var watches: [ObjectIdentifier: Watch] = [:]
    private var rule = MonitorHandover()
    /// The remote position of the last motion over the target's picture.
    private var lastPosition: (x: Double, y: Double)?
    private var timer: Task<Void, Never>?
    /// The deadline the timer is armed for.
    private var armedFor: Duration?
    private let origin = ContinuousClock.now

    private init() {}

    private var now: Duration { .now - origin }

    /// A capture's group or video view changed: the watchers follow.
    func changed(_ capture: CaptureController) {
        captures.add(capture)
        updateWatchers()
    }

    /// A capture's window became key or stopped being key. A new key window stops the count
    /// and drops a handover's entry point left with any other window; the watchers follow.
    func keyChanged(_ capture: CaptureController, isKey: Bool) {
        captures.add(capture)
        let newKey = isKey ? capture : (key === capture ? nil : key)
        // A session starting applies the window's key state again: no change.
        if newKey !== key {
            key = newKey
            rule.keyChanged(to: newKey.map(ObjectIdentifier.init))
            disarm()
            if isKey {
                for other in captures.allObjects where other !== capture { other.entry.clear() }
            }
        }
        updateWatchers()
    }

    /// Each live mirror's picture is watched while its window isn't key. A watch whose view or
    /// capture went, or whose view's address a new view took, is replaced.
    private func updateWatchers() {
        var wanted: [ObjectIdentifier: (capture: CaptureController, view: VideoNSView)] = [:]
        for capture in captures.allObjects {
            guard capture.handoverGroup != nil, let view = capture.videoView, let window = view.window,
                window === capture.window, !window.isKeyWindow
            else { continue }
            wanted[ObjectIdentifier(view)] = (capture, view)
        }
        for (id, watch) in watches
        where wanted[id]?.view !== watch.watcher.view || wanted[id]?.capture !== watch.capture {
            watch.watcher.remove()
            watches[id] = nil
        }
        for (id, (capture, view)) in wanted where watches[id] == nil {
            let watcher = PictureHoverWatcher(
                view: view,
                moved: { [weak self, weak capture, weak view] event in
                    guard let capture, let view else { return }
                    self?.moved(over: capture, view, event)
                },
                exited: { [weak self, weak capture] in
                    guard let capture else { return }
                    self?.exited(capture)
                })
            watches[id] = Watch(watcher: watcher, capture: capture)
        }
    }

    private func moved(over target: CaptureController, _ view: VideoNSView, _ event: NSEvent) {
        // While the key window can't leave, no mapping and no window-server query.
        guard let source = key, case let facts = source.handoverFacts, facts.canLeave else {
            stopCount()
            return
        }
        let mapped = view.remotePosition(ofWindowPoint: event.locationInWindow)
        let answer = rule.moved(
            over: ObjectIdentifier(target), source: facts, target: target.handoverFacts,
            pointer: pointer(over: view, at: event.locationInWindow, inside: mapped?.inside == true),
            at: now)
        // Only the counted window's motions: a covered one maps the point in its own picture.
        if rule.target == ObjectIdentifier(target) || answer == .handOver { lastPosition = mapped?.position }
        self.answer(answer, target: target)
    }

    private func exited(_ target: CaptureController) {
        if rule.target == ObjectIdentifier(target) { stopCount() }
    }

    /// The deadline came: the facts again, where the pointer is now.
    private func tick() {
        armedFor = nil
        guard let id = rule.target,
            let target = captures.allObjects.first(where: { ObjectIdentifier($0) == id }),
            let view = target.videoView, let location = view.window?.mouseLocationOutsideOfEventStream,
            let source = key, source.handoverFacts.canLeave
        else {
            stopCount()
            return
        }
        let mapped = view.remotePosition(ofWindowPoint: location)
        lastPosition = mapped?.position
        answer(
            rule.tick(
                source: source.handoverFacts, target: target.handoverFacts,
                pointer: pointer(over: view, at: location, inside: mapped?.inside == true), at: now),
            target: target)
    }

    /// The app's and the pointer's facts, the pointer at the window `location` over `view`,
    /// `inside` its picture. The window server is asked what is frontmost there only when the
    /// app is active and no button is held.
    private func pointer(over view: VideoNSView, at location: NSPoint, inside: Bool) -> HandoverPointer {
        let appActive = NSApplication.shared.isActive
        let buttonHeld = NSEvent.pressedMouseButtons != 0
        return HandoverPointer(
            appActive: appActive, buttonHeld: buttonHeld, overPicture: inside,
            frontmostAtPoint: appActive && !buttonHeld && view.isHit(at: location))
    }

    private func answer(_ answer: MonitorHandover.Answer, target: CaptureController) {
        switch answer {
        case .nothing: disarm()
        case .waitUntil(let deadline): arm(deadline)
        case .handOver:
            disarm()
            handOver(to: target)
        }
    }

    /// After the event that answered: the key change removes watchers, and a tracking area
    /// doesn't retain the watcher whose event it is delivering.
    private func handOver(to target: CaptureController) {
        Task { [weak target, lastPosition] in
            guard let target, let window = target.window else { return }
            if let lastPosition { target.entry.set(x: lastPosition.x, y: lastPosition.y, at: .now) }
            Self.logger.debug("the pointer hands over to another monitor's window")
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func stopCount() {
        rule.reset()
        disarm()
    }

    /// The timer, re-armed only when the deadline changes.
    private func arm(_ deadline: Duration) {
        guard deadline != armedFor else { return }
        timer?.cancel()
        armedFor = deadline
        timer = Task { [weak self, origin] in
            do { try await Task.sleep(until: origin + deadline, clock: .continuous) } catch { return }
            // Cancelled after the sleep ended, while queued: disarmed or re-armed.
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private func disarm() {
        timer?.cancel()
        (timer, armedFor) = (nil, nil)
    }
}
