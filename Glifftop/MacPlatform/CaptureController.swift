import AppKit
import GliffInput
import GliffSession
import Observation

/// Input capture for one window's session, keys and pointer together: feeds `InputController`
/// what capture depends on (the window key, the app active, the picture, the link, sleep and
/// lock), takes the window's key events while there is a picture, takes the pointer events the
/// video view hands it, and sends what it says through the session.
@Observable final class CaptureController {
    private(set) var isCaptured = false
    /// Input ▸ Release Input has something to release (`InputController.isReleasable`).
    private(set) var isReleasable = false
    /// The mode's input hint (`InputHintView`), for 3 s at a time.
    private(set) var showsHint = false
    /// The Mac pointer is held over the picture (Capture mode): its cursor is hidden. Follows
    /// `confinement`.
    private(set) var isConfined = false

    /// The session's input rules; `CaptureController+Confinement.swift` drives its pointer too.
    @ObservationIgnored var controller: InputController?
    /// Holds the Mac pointer while confined (`CaptureController+Confinement.swift`).
    @ObservationIgnored var confinement: PointerConfinement? {
        didSet {
            isConfined = confinement != nil
            confinementChanged()
        }
    }
    /// Where the session's host pointer is (`attach`): the confined pointer follows its warps.
    @ObservationIgnored var hostPointer: HostPointerFollower?
    /// The start of the clock the confined pointer's times count from.
    @ObservationIgnored let clockStart = ContinuousClock.now
    /// The pointer's place last reported (`.pointerOnPicture`); nil once anything else is
    /// applied, so the next report goes through again (after a suspension, an edge, a fall).
    @ObservationIgnored var hovering: Bool?
    /// When full screen began being entered or left (the frame moving), until it ends: the
    /// pointer can't be held meanwhile.
    @ObservationIgnored var transitionStarted: Duration?
    /// Another app coming forward (this one still active for a moment): the pointer can't be
    /// held until this app is active and in front again.
    @ObservationIgnored var leaving = false
    /// This app about to resign: the pointer can't be held until it resigns or is active again.
    @ObservationIgnored var resigning = false
    @ObservationIgnored private var send: ((InputMessage) -> Void)?
    /// An activation's motions to the session (`Session.activate`).
    @ObservationIgnored private var activateSession: (([InputMessage]) -> Void)?
    @ObservationIgnored private(set) weak var window: NSWindow?
    @ObservationIgnored private var picture = false
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored var windowObservers: [any NSObjectProtocol] = []
    /// App, workspace and distributed observers, each with its centre: for the controller's life.
    @ObservationIgnored var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private var hintTimer: Task<Void, Never>?
    /// One for every window: the chord's repeats and key-up reach the window it moved to.
    @ObservationIgnored private static var chordKeys = TabChordKeys()
    /// ⌘⇧[ or ⌘⇧] over the picture, captured or not, with the window's number: kept from the
    /// remote, its repeats and key-up too.
    @ObservationIgnored var onTabChord: (TabChord, Int?) -> Void = { _, _ in }
    /// The window's video view: the Mac pointer over its uncovered picture is an activation's
    /// first choice, and its frame tells the picture from the chrome for ⌘ chords.
    @ObservationIgnored weak var videoView: VideoNSView?
    /// Integrated or Capture: applied on change, and to each session attached.
    var mode: CaptureMode = .integrated {
        didSet { if mode != oldValue { apply(.mode(mode)) } }
    }
    /// Where an activation puts the remote pointer, given the Mac pointer's place: the session's
    /// (`attach`), nil without a stream, and then nothing is sent.
    @ObservationIgnored private(set) var target: ((x: Double, y: Double)?) -> (x: Double, y: Double)? = { _ in
        nil
    }

    init() { observeApp() }

    isolated deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if let monitor { NSEvent.removeMonitor(monitor) }
        hintTimer?.cancel()
    }

    /// A session started, its Hello with no keymap: `send` queues input for it, the Mac's
    /// layout first, and `activate` an activation's motions.
    func attach(
        target: @escaping ((x: Double, y: Double)?) -> (x: Double, y: Double)?,
        send: @escaping (InputMessage) -> Void, activate: @escaping ([InputMessage]) -> Void,
        pointer: RemotePointerSlot
    ) {
        detach()
        controller = InputController(mode: mode, keymap: "")
        (self.target, self.send, activateSession) = (target, send, activate)
        hostPointer = HostPointerFollower(pointer)
        keymapChanged()
        // The menu first: capture never rises under an open menu.
        apply(.menuOpen(MenuTracker.shared.isOpen))
        apply(.appActive(NSApplication.shared.isActive))
        apply(.windowKey(window?.isKeyWindow ?? false))
        apply(.picture(picture))
        apply(.interrupted(interrupted))
        updateMonitor()
    }

    /// The session is going: let go of what the remote holds, then stop.
    func detach() {
        apply(.picture(false))
        controller = nil
        (send, activateSession, hostPointer) = (nil, nil, nil)
        updateMonitor()
        hideHint()
    }

    /// The window and what the window shows, from `CaptureTracker`; acts on changes only.
    func update(window: NSWindow?, picture: Bool, interrupted: Bool) {
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

    func apply(_ event: CaptureEvent) {
        if case .pointerOnPicture = event {} else { hovering = nil }
        if case .appActive(let active) = event {
            resigning = false
            if active { leaving = false }
        }
        // Where the pointer is, before the edge it may confine at.
        if event == .windowKey(true) || event == .appActive(true) { reportEntry() }
        guard let result = controller?.capture(event) else { return }
        handle(result)
    }

    /// An activation's nudge goes before anything else; confinement follows what it says.
    func handle(_ result: InputResult) {
        let captured = controller?.isCaptured ?? false
        if result.activates { activate() }
        for message in result.messages { send?(message) }
        if result.showHint { flashHint() }
        if captured != isCaptured { isCaptured = captured }
        let releasable = controller?.isReleasable ?? false
        if releasable != isReleasable { isReleasable = releasable }
        // The hint says how to release input: gone once it is released.
        if !captured { hideHint() }
        updateConfinement()
    }

    /// Two motions onto the activation target, so the host's focus follows to this screen;
    /// input sent next waits for it (`Session.activate`).
    private func activate() {
        guard let target = target(videoView?.macPointerOverPicture()),
            let result = controller?.activate(at: target)
        else { return }
        activateSession?(result.messages)
    }

    func reactivate() {
        if isCaptured { activate() }
    }

    func keymapChanged() {
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
        guard let result = controller?.key(key, overChrome: { overChrome(event) }) else { return event }
        handle(result)
        return result.consumed ? nil : event
    }

    /// Whether `event` happened over the window's chrome (Integrated's ⌘ chords are the Mac's
    /// there); without a video view in the window, over the picture.
    private func overChrome(_ event: NSEvent) -> Bool {
        guard let window, let videoView, videoView.window === window else { return false }
        return ChromeProbe.place(of: event, keyWindow: window, videoView: videoView) == .chrome
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
}
