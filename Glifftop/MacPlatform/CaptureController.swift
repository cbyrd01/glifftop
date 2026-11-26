import AppKit
import GliffInput
import Observation

/// Input capture for one window's session, keys and pointer together: feeds `InputController`
/// what capture depends on (the window key, the app active, the picture, the link, a popover
/// over the window, sleep and lock), takes the window's key events while there is a picture, takes the pointer events the
/// video view hands it, and sends what it says through the session.
@Observable final class CaptureController {
    private(set) var isCaptured = false
    /// The "Shift+Esc releases input" hint, for 3 s at a time.
    private(set) var showsHint = false

    @ObservationIgnored private var controller: InputController?
    @ObservationIgnored private var send: ((InputMessage) -> Void)?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var picture = false
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var popover = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var windowObservers: [any NSObjectProtocol] = []
    /// App, workspace and distributed observers, each with its centre: for the controller's life.
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private var hintTimer: Task<Void, Never>?
    /// One for every window: the chord's repeats and key-up reach the window it moved to.
    @ObservationIgnored private static var chordKeys = TabChordKeys()
    /// ⌘⇧[ or ⌘⇧] over the picture, captured or not, with the window's number: kept from the
    /// remote, its repeats and key-up too.
    @ObservationIgnored var onTabChord: (TabChord, Int?) -> Void = { _, _ in }
    /// The Mac pointer over the uncovered picture, in remote coordinates (`VideoNSView`): an
    /// activation's first choice, set by the window's video view.
    @ObservationIgnored var macPointer: () -> (x: Double, y: Double)? = { nil }
    /// Where an activation puts the remote pointer, given `macPointer`'s answer: the session's
    /// (`attach`), nil without a stream, and then nothing is sent.
    @ObservationIgnored private var target: ((x: Double, y: Double)?) -> (x: Double, y: Double)? = { _ in nil
    }

    init() {
        let app = NotificationCenter.default
        observe(app, NSApplication.didBecomeActiveNotification) { $0.apply(.appActive(true)) }
        observe(app, NSApplication.didResignActiveNotification) { $0.apply(.appActive(false)) }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            observe(workspace, name) { $0.apply(.away) }
        }
        // Back from sleep, a lock or another user: the host's focus again, if still captured.
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { $0.reactivate() }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.apply(.away) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.reactivate() }
        observe(distributed, InputSource.changed) { $0.keymapChanged() }
    }

    isolated deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if let monitor { NSEvent.removeMonitor(monitor) }
        hintTimer?.cancel()
    }

    /// A session started, its Hello with no keymap: `send` queues input for it, the Mac's
    /// layout first.
    func attach(
        target: @escaping ((x: Double, y: Double)?) -> (x: Double, y: Double)?,
        send: @escaping (InputMessage) -> Void
    ) {
        detach()
        controller = InputController(keymap: "")
        (self.target, self.send) = (target, send)
        keymapChanged()
        apply(.appActive(NSApplication.shared.isActive))
        apply(.windowKey(window?.isKeyWindow ?? false))
        apply(.picture(picture))
        apply(.interrupted(interrupted))
        apply(.popover(popover))
        updateMonitor()
    }

    /// The session is going: let go of what the remote holds, then stop.
    func detach() {
        apply(.picture(false))
        controller = nil
        send = nil
        updateMonitor()
        hideHint()
    }

    /// The window, what the window shows and whether a popover is over it, from
    /// `CaptureTracker`; acts on changes only.
    func update(window: NSWindow?, picture: Bool, interrupted: Bool, popover: Bool) {
        if window !== self.window {
            self.window = window
            observeWindow()
            apply(.windowKey(window?.isKeyWindow ?? false))
        }
        if picture != self.picture {
            self.picture = picture
            apply(.picture(picture))
        }
        if interrupted != self.interrupted {
            self.interrupted = interrupted
            apply(.interrupted(interrupted))
        }
        if popover != self.popover {
            self.popover = popover
            apply(.popover(popover))
        }
        updateMonitor()
    }

    /// A pointer event over the picture, in remote coordinates (`VideoNSView`). True when it was
    /// for the remote (or took input back) and must not reach the Mac.
    func pointer(_ event: PointerEvent) -> Bool {
        guard let result = controller?.pointer(event) else { return false }
        handle(result)
        return result.consumed
    }

    /// Input ▸ Release Input.
    func release() { apply(.release) }

    private func apply(_ event: CaptureEvent) {
        guard let result = controller?.capture(event) else { return }
        handle(result)
    }

    /// Capture turning on is an activation: its nudge goes before anything else.
    private func handle(_ result: InputResult) {
        let captured = controller?.isCaptured ?? false
        if captured, !isCaptured { activate() }
        for message in result.messages { send?(message) }
        if result.showHint { flashHint() }
        if captured != isCaptured { isCaptured = captured }
        // The hint says how to release input: gone once it is released.
        if !captured { hideHint() }
    }

    /// Two motions onto the activation target, so the host's focus follows to this screen.
    private func activate() {
        guard let target = target(macPointer()), let result = controller?.activate(at: target) else { return }
        for message in result.messages { send?(message) }
    }

    private func reactivate() {
        if isCaptured { activate() }
    }

    private func keymapChanged() {
        // Optional chaining skips reading the layout when there is no session.
        guard let message = controller?.keymap(InputSource.currentKeymap()) else { return }
        send?(message)
    }

    /// The window's key events reach `key(_:)` while there is a session, a window and a picture.
    private func updateMonitor() {
        let wanted = controller != nil && window != nil && picture
        if wanted, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
                [weak self] event in
                // Not `self?.key(event) ?? event`: key(_:) returns nil to swallow the event, and
                // the coalescing would pass every swallowed event on to the Mac (a beep a key).
                guard let self else { return event }
                return self.key(event)
            }
        } else if !wanted, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// nil (swallowed) when the event was for the remote.
    private func key(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, let key = MacKeyEvent(event) else { return event }
        switch Self.chordKeys.take(key) {
        case .chord(let chord):
            onTabChord(chord, window?.windowNumber)
            return nil
        case .swallowed: return nil
        case .passed: break
        }
        guard let result = controller?.key(key) else { return event }
        handle(result)
        return result.consumed ? nil : event
    }

    private func flashHint() {
        showsHint = true
        hintTimer?.cancel()
        hintTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.showsHint = false
        }
    }

    private func hideHint() {
        hintTimer?.cancel()
        if showsHint { showsHint = false }
    }

    private func observeWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        for (name, key) in [
            (NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false),
        ] {
            windowObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.apply(.windowKey(key)) }
                })
        }
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ action: @escaping @MainActor (CaptureController) -> Void
    ) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        observers.append((center, observer))
    }
}
