import AppKit
import GliffInput
import os

/// The ⌘Q guard (`QuitHold`) in the app: a ⌘ key-down that reached Quit while a session is
/// live shows "Hold ⌘Q to Quit" (`QuitHoldPanel`); held 1 s, or pressed again while the message
/// shows, it quits. Its key-ups come from an observing local monitor, and a timer checks the
/// keys' real state when the hold is due. Times are the events' own, so a busy main thread
/// can't turn a tap into a hold.
@MainActor final class QuitGuard {
    private static let logger = Logger(subsystem: "io.github.cbyrd01.Glifftop", category: "quit")

    /// The guard confirmed a quit: the next quit passes.
    private var confirmed = false
    private var hold = QuitHold()
    /// The origin of `QuitHold`'s times.
    private let start = ContinuousClock.now
    /// The key of the press being held (Q, or whichever key Quit's equivalent is).
    private var keyCode: UInt16 = 0
    private var monitor: Any?
    private var timer: (task: Task<Void, Never>, deadline: Duration)?
    private let panel = QuitHoldPanel()

    private var now: Duration { ContinuousClock.now - start }

    /// Whether a quit whose current event is `event` is held back: a key-down with ⌘ (Quit's
    /// key equivalent, whatever the layout) while `guarded`, which shows the message or counts
    /// as a press. A quit the guard confirmed passes, once; Quit from a menu, the Dock, logout
    /// or restart is never held back.
    func holdsBack(_ event: NSEvent?, guarded: Bool) -> Bool {
        if confirmed {
            confirmed = false
            return false
        }
        // An Apple event's quit (logout, restart, the Dock, a script) passes, whatever event
        // came last.
        guard guarded, NSAppleEventManager.shared().currentAppleEvent == nil, let event,
            event.type == .keyDown, event.modifierFlags.contains(.command)
        else {
            return false
        }
        keyCode = event.keyCode
        perform(hold.keyDown(isRepeat: event.isARepeat, at: time(of: event)))
        return true
    }

    /// When `event` happened, on `QuitHold`'s clock: events carry the system uptime.
    private func time(of event: NSEvent) -> Duration {
        now - .seconds(max(ProcessInfo.processInfo.systemUptime - event.timestamp, 0))
    }

    private func perform(_ action: QuitHold.Action) {
        switch action {
        case .none: return
        case .show: panel.show()
        case .hide: panel.hide()
        case .quit:
            Self.logger.info("quit confirmed")
            // Gone with the app; hidden too, should the quit be cancelled.
            panel.hide()
            confirmed = true
            // From the run loop, not inside this call: within `applicationShouldTerminate` (a
            // second press) or a main-actor job (the timer), quitting would wait on itself.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
        follow()
    }

    /// While the message shows: the monitor for the key-ups, and the timer to the next
    /// deadline. Neither once it has gone.
    private func follow() {
        guard let deadline = hold.nextDeadline else {
            timer?.task.cancel()
            timer = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            return
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged]) {
                [weak self] event in
                self?.observe(event)
                return event
            }
        }
        guard timer?.deadline != deadline else { return }
        timer?.task.cancel()
        let task = Task { [weak self, start] in
            try? await Task.sleep(until: start + deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.tick()
        }
        timer = (task, deadline)
    }

    /// The held key's key-up, or ⌘ let go: the hold ends.
    private func observe(_ event: NSEvent) {
        let letGo =
            event.type == .keyUp
            ? event.keyCode == keyCode
            : !event.modifierFlags.contains(.command)
        if letGo { perform(hold.keyUp(at: time(of: event))) }
    }

    /// The deadline: whether ⌘ and the key are really still down (a key-up may have gone
    /// elsewhere).
    private func tick() {
        timer = nil
        let keysDown =
            NSEvent.modifierFlags.contains(.command)
            && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
        perform(hold.tick(at: now, keysDown: keysDown))
    }
}
