import GliffProtocol

/// What the app does with an input event, from `InputController`.
public struct InputResult: Sendable, Equatable {
    /// Swallow the event: it was for the remote (every key and pointer event while captured,
    /// ⌘ chords included), or it took input back. Captured keys that pass to the Mac: in
    /// Integrated, a ⌘ key-down or a modifier press with ⌘ held over the chrome, a chord key's
    /// repeats while ⌘ is held and its key-up; and a key-up whose press the remote never had.
    public var consumed: Bool
    /// To send, in order.
    public var messages: [InputMessage]
    /// Show the mode's hint (how to release input).
    public var showHint: Bool

    /// Capture rose because the window or app came to the front, or input came back: the host's
    /// focus should follow (`activate(at:)`).
    public var activates: Bool

    public init(
        consumed: Bool = false, messages: [InputMessage] = [], showHint: Bool = false, activates: Bool = false
    ) {
        self.consumed = consumed
        self.messages = messages
        self.showHint = showHint
        self.activates = activates
    }
}

/// The input rules for one session, as the app drives them: one capture for keys and pointer,
/// what each event means, and the ledger of what the remote holds. Keys and pointer input are
/// sent only while captured; every way capture ends releases what is held (buttons, then
/// keys) and stops a scroll under way; keymap changes are sent whatever the capture. A click on
/// the picture when only Shift+Esc holds capture off takes input back: its buttons never reach
/// the remote nor its up the Mac, and nothing from the pointer is sent until its up, which
/// moves the remote pointer to where it was let go.
/// Each captured click, scroll and key that sends something first syncs the held modifiers
/// from its flags (`syncModifiers`), so a modifier pressed where its press went to the Mac
/// (⌘Tab back with ⌘ held) joins it, and one whose release went missing is let go.
/// In Integrated, a ⌘ chord with the pointer over Glifftop's chrome is the Mac's
/// (`key(_:overChrome:)`). Confined, deltas move a virtual pointer (`InputController+Confined`).
public struct InputController: Sendable {
    private var capture: InputCapture
    var ledger = InputLedger()
    private var lastKeymap: String
    /// After Shift+Esc, Esc stays away from the Mac (its repeats, its key-up) until it's up.
    private var swallowingEsc = false
    /// ⌘ chord keys whose key-down went to the Mac over the chrome.
    private var chordKeys = MacChordKeys()
    /// The button whose click took input back: until its up, nothing from the pointer is sent.
    var recapturingButton: Int?
    /// A recapturing click that capture ended before its up: its up still stays from the Mac.
    private var strayUp: Int?
    /// Where the remote pointer was last sent, while that is known. Motion isn't sent while
    /// released (nor reported while the window isn't key), so a press or scroll elsewhere moves
    /// it there first. A captured key may move it (a focus binding warps it), and motion may
    /// have been dropped as the link went: those forget it, so the next press moves it.
    var remoteAt: (x: Double, y: Double)?
    /// The confined pointer (`InputController+Confined`): nil unless confined.
    var virtual: VirtualPointer?
    /// Capture mode's absolute motions sent lately (at most `recentLimit`), whose echoes a
    /// confinement starting now may still see. A captured key (which may move the host's
    /// pointer), the pointer leaving the picture and capture ending forget them.
    var recentMotions: [(x: Double, y: Double)] = []
    static let recentLimit = 64
    /// The picture the virtual pointer's coordinates belong to.
    var virtualGeometry: PictureGeometry?
    /// Where the virtual pointer was when confinement last ended, for the app to put the Mac
    /// cursor there; nil once confinement starts again.
    public internal(set) var unconfinedAt: (x: Double, y: Double)?
    /// Precise axes scrolled since their last stop: capture ending stops them. A wheel has no
    /// gesture to end.
    private var scrolling: Set<Axis> = []

    /// `keymap` is the one the server has already (the app's Hello carries none: "").
    public init(mode: CaptureMode = .integrated, keymap: String) {
        capture = InputCapture(mode: mode)
        lastKeymap = keymap
    }

    public var isCaptured: Bool { capture.isCaptured }
    public var mode: CaptureMode { capture.mode }
    /// `InputCapture.isReleasable`.
    public var isReleasable: Bool { capture.isReleasable }
    public var isConfined: Bool { capture.isConfined }

    /// A key event, with the pointer on the picture.
    public mutating func key(_ event: MacKeyEvent) -> InputResult {
        key(event, overChrome: { false })
    }

    /// A key event. In Integrated, an event with ⌘ in its flags that would reach the host (a
    /// fresh key-down, a modifier's press, a held key's release, a Caps Lock toggle) asks
    /// `overChrome` (at most once) whether the pointer is over Glifftop's chrome. There, a
    /// key-down goes to the Mac after the host lets go of every key it holds, and its repeats
    /// and key-up follow it; a modifier's press goes to the Mac; a release or toggle goes to the
    /// host without pressing Super, whose press went to the Mac.
    public mutating func key(_ event: MacKeyEvent, overChrome: () -> Bool) -> InputResult {
        if swallowingEsc, event.keyCode == MacKeyTranslator.escape {
            // Only its repeats keep it going: its key-up ends it, and so does a fresh press (a
            // new Esc; the key-up of the one that released may have gone elsewhere).
            swallowingEsc = event.kind == .down(isRepeat: true)
            if event.kind != .down(isRepeat: false) { return InputResult(consumed: true) }
        }
        guard capture.isCaptured else { return InputResult() }
        if chordKeys.take(event) {
            // With ⌘ let go, its repeats are no shortcut: kept from the Mac, which would beep. Its
            // flags still let go of the stale modifiers.
            let plainRepeat =
                event.kind == .down(isRepeat: true)
                && !event.modifiers.contains(.command)
            return InputResult(consumed: plainRepeat, messages: releaseStaleModifiers(event.flags))
        }
        let action = MacKeyTranslator.action(for: event)
        let commandOverChrome = asksWhere(event, action) && overChrome()
        if commandOverChrome {
            if event.kind == .down(isRepeat: false) {
                chordKeys.hold(event.keyCode)
                let releases = ledger.releaseAllKeys()
                // A release can trigger a binding that moves the pointer.
                if !releases.isEmpty { remoteAt = nil }
                return InputResult(messages: releases)
            }
            // A modifier's press sends nothing of its own, but lets go of the stale ones.
            if case .press = action { return InputResult(messages: releaseStaleModifiers(event.flags)) }
        }
        remoteAt = nil
        recentMotions = []
        // Each key that sends something first syncs the held modifiers from its flags (over the
        // chrome, only letting go of the stale ones); any other still lets go of the stale ones.
        func sync(except code: UInt32? = nil) -> [InputMessage] {
            commandOverChrome
                ? releaseStaleModifiers(event.flags, except: code) : syncModifiers(event.flags, except: code)
        }
        let messages: [InputMessage]
        switch action {
        case .press(let code): messages = sync(except: code) + ledger.press(key: code)
        case .release(let code):
            // A key-up the host doesn't hold goes to the Mac: its press went there (over the
            // chrome, before capture), or the host already let go of it. A release never
            // triggers a Mac shortcut.
            guard let release = ledger.release(key: code) else {
                return InputResult(messages: releaseStaleModifiers(event.flags, except: code))
            }
            // `except` keeps a modifier's own release from counting as stale; the sync is sent
            // before the release.
            messages = sync(except: code) + [release]
        case .toggle(let code):
            messages = sync() + [.key(code: code, pressed: true), .key(code: code, pressed: false)]
        case .releaseKeyboard:
            swallowingEsc = true
            return InputResult(consumed: true, messages: capture(.release).messages)
        // A repeat, Fn or an unknown key sends nothing of its own, but its flags still let go
        // of a modifier whose release went missing.
        case .ignore: messages = releaseStaleModifiers(event.flags)
        }
        return InputResult(consumed: true, messages: messages)
    }

    /// Integrated's question, for an event with ⌘ in its flags that would reach the host: a
    /// fresh key-down, a modifier's press, a held key's release, a Caps Lock toggle.
    private func asksWhere(_ event: MacKeyEvent, _ action: KeyAction) -> Bool {
        guard capture.mode == .integrated, event.modifiers.contains(.command) else {
            return false
        }
        if event.kind == .down(isRepeat: false) { return true }
        switch action {
        case .press, .toggle: return true
        case .release(let code): return ledger.heldKeys.contains(code)
        case .releaseKeyboard, .ignore: return false
        }
    }

    /// The `Keymap` to send for new keymap text, or nil when it's empty or unchanged.
    public mutating func keymap(_ text: String) -> InputMessage? {
        guard !text.isEmpty, text != lastKeymap else { return nil }
        lastKeymap = text
        return .keymap(text)
    }

    public mutating func pointer(_ event: PointerEvent) -> InputResult {
        if let stray = strayUp, case .button(stray, let pressed, _, _, _) = event {
            strayUp = nil
            if !pressed { return InputResult(consumed: true) }
        }
        if let held = recapturingButton {
            switch event {
            // A fresh press of it: its up was missed.
            case .button(held, pressed: true, _, _, _): recapturingButton = nil
            // Its up moves the remote pointer to where it was let go, so keys typed next go
            // where the Mac's pointer is (confined, the virtual pointer, dragged on).
            case .button(held, pressed: false, let x, let y, _):
                recapturingButton = nil
                return InputResult(consumed: true, messages: move(virtual?.x ?? x, virtual?.y ?? y))
            default: return InputResult(consumed: true)
            }
        }
        guard capture.isCaptured else {
            guard case .button(let number, pressed: true, _, _, _) = event, capture.clickRecaptures else {
                return InputResult()
            }
            recapturingButton = number
            var result = capture(.pictureClicked)
            result.consumed = true
            return result
        }
        let messages: [InputMessage]
        switch event {
        // Confined, the Mac pointer's place isn't the remote's: deltas move it.
        case .moved(let x, let y):
            return InputResult(consumed: true, messages: virtual == nil ? move(x, y) : [])
        case .button(let number, let pressed, _, _, _):
            guard let code = PointerButtons.code(forButtonNumber: number) else {
                return InputResult(consumed: true)
            }
            messages = pressed ? ledger.press(button: code) : ledger.release(button: code).map { [$0] } ?? []
        case .scroll(let scroll, _, _, _):
            messages = ScrollTranslator.messages(for: scroll)
            for case .pointerAxis(let axis, _, nil, let stop) in messages {
                if stop { scrolling.remove(axis) } else { scrolling.insert(axis) }
            }
        }
        guard !messages.isEmpty else { return InputResult(consumed: true) }
        // The held modifiers, then the motion to its position (confined, the virtual pointer's),
        // then the button or scroll.
        let sync = syncModifiers(event.flags)
        let at = virtual.map { (x: $0.x, y: $0.y) } ?? event.position
        return InputResult(consumed: true, messages: sync + move(at.x, at.y) + messages)
    }

    /// The window came to the front: while captured, two motions, the first a pixel off and
    /// the second on `target`, so the host sees the pointer arrive and its focus follows.
    /// Released, nothing (motion isn't sent while released).
    public mutating func activate(at target: (x: Double, y: Double)) -> InputResult {
        guard capture.isCaptured else { return InputResult() }
        let nudge = target.x < 1 ? target.x + 1 : target.x - 1
        remoteAt = nil
        return InputResult(messages: move(nudge, target.y) + move(target.x, target.y))
    }

    /// A motion to (x, y), unless the remote pointer is there already.
    mutating func move(_ x: Double, _ y: Double) -> [InputMessage] {
        if let remoteAt, remoteAt == (x, y) { return [] }
        remoteAt = (x, y)
        if virtual == nil, capture.mode == .confined {
            recentMotions.append((x, y))
            if recentMotions.count > Self.recentLimit { recentMotions.removeFirst() }
        }
        return [.pointerMotion(x: x, y: y)]
    }

    public mutating func capture(_ event: CaptureEvent) -> InputResult {
        let change = capture.apply(event)
        let wasConfined = virtual != nil
        if !capture.isConfined { unconfine() }
        if event == .pointerOnPicture(false) { recentMotions = [] }
        var result = InputResult(showHint: change.showHint, activates: change.activates)
        // A recapturing click cut short (its up gone elsewhere, or never coming after sleep or
        // a lock) is forgotten.
        guard !capture.isCaptured || event == .away else {
            // Confinement ended mid-drag (a suspension): the release may go elsewhere, so up now.
            if wasConfined, virtual == nil { result.messages = ledger.releaseAllButtons() }
            return result
        }
        if let held = recapturingButton { strayUp = held }
        recapturingButton = nil
        remoteAt = nil
        recentMotions = []
        // A chord key's key-up may go to another window now.
        chordKeys = MacChordKeys()
        let stops = [Axis.vertical, .horizontal].filter(scrolling.contains).map {
            InputMessage.pointerAxis(axis: $0, value: 0, discrete: nil, stop: true)
        }
        scrolling = []
        result.messages = stops + ledger.releaseAll()
        return result
    }
}
