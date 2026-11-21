import GliffProtocol

/// What the app does with an input event, from `InputController`.
public struct InputResult: Sendable, Equatable {
    /// Swallow the event: it was for the remote (every key and pointer event while captured,
    /// ⌘ chords included, so none reaches the Mac's menus), or it took input back.
    public var consumed: Bool
    /// To send, in order.
    public var messages: [InputMessage]
    /// Show the "Shift+Esc releases input" hint.
    public var showHint: Bool

    public init(consumed: Bool = false, messages: [InputMessage] = [], showHint: Bool = false) {
        self.consumed = consumed
        self.messages = messages
        self.showHint = showHint
    }
}

/// The input rules for one session, as the app drives them: one capture for keys and pointer,
/// what each event means, and the ledger of what the remote holds. Keys and pointer input are
/// sent only while captured; every way capture ends releases what is held (buttons, then
/// keys) and stops a scroll under way; keymap changes are sent whatever the capture. A click on
/// the picture when only Shift+Esc holds capture off takes input back: its buttons never reach
/// the remote nor its up the Mac, and nothing from the pointer is sent until its up, which
/// moves the remote pointer to where it was let go.
/// Every captured event's flags let go of modifiers whose release went missing, and each
/// captured key-down first presses those the flags hold that the remote doesn't, so a modifier
/// pressed before capture (⌘Tab back with ⌘ held) still joins the key.
public struct InputController: Sendable {
    private var capture: InputCapture
    private var ledger = InputLedger()
    private var lastKeymap: String
    /// After Shift+Esc, Esc stays away from the Mac (its repeats, its key-up) until it's up.
    private var swallowingEsc = false
    /// The button whose click took input back: until its up, nothing from the pointer is sent.
    private var recapturingButton: Int?
    /// A recapturing click that capture ended before its up: its up still stays from the Mac.
    private var strayUp: Int?
    /// Where the remote pointer was last sent, while that is known. Motion isn't sent while
    /// released (nor reported while the window isn't key), so a press or scroll elsewhere moves
    /// it there first. A captured key may move it (a focus binding warps it), and motion may
    /// have been dropped as the link went: those forget it, so the next press moves it.
    private var remoteAt: (x: Double, y: Double)?
    /// Precise axes scrolled since their last stop: capture ending stops them. A wheel has no
    /// gesture to end.
    private var scrolling: Set<Axis> = []

    /// `keymap` is the one the server has already (the app's Hello carries none: "").
    public init(mode: CaptureMode = .windowInFront, keymap: String) {
        capture = InputCapture(mode: mode)
        lastKeymap = keymap
    }

    public var isCaptured: Bool { capture.isCaptured }

    public mutating func key(_ event: MacKeyEvent) -> InputResult {
        if swallowingEsc, event.keyCode == MacKeyTranslator.escape {
            // Only its repeats keep it going: its key-up ends it, and so does a fresh press (a
            // new Esc; the key-up of the one that released may have gone elsewhere).
            swallowingEsc = event.kind == .down(isRepeat: true)
            if event.kind != .down(isRepeat: false) { return InputResult(consumed: true) }
        }
        guard capture.isCaptured else { return InputResult() }
        remoteAt = nil
        // Every event's flags let go of modifiers whose key-up never came.
        let releases = releaseStaleModifiers(event.flags)
        let messages: [InputMessage]
        switch MacKeyTranslator.action(for: event) {
        case .press(let code):
            let presses = event.kind == .flagsChanged ? [] : pressMissingModifiers(event.flags)
            messages = presses + ledger.press(key: code)
        case .release(let code): messages = ledger.release(key: code).map { [$0] } ?? []
        case .toggle(let code):
            messages = [.key(code: code, pressed: true), .key(code: code, pressed: false)]
        case .releaseKeyboard:
            swallowingEsc = true
            return InputResult(consumed: true, messages: releases + capture(.release).messages)
        case .ignore: messages = []
        }
        return InputResult(consumed: true, messages: releases + messages)
    }

    /// The `Keymap` to send for new keymap text, or nil when it's empty or unchanged.
    public mutating func keymap(_ text: String) -> InputMessage? {
        guard !text.isEmpty, text != lastKeymap else { return nil }
        lastKeymap = text
        return .keymap(text)
    }

    /// Releases for modifiers the remote holds that `flags` says are up, last pressed first.
    private mutating func releaseStaleModifiers(_ flags: UInt) -> [InputMessage] {
        let up = MacKeyTranslator.modifiersUp(flags)
        return ledger.heldKeys.filter(up.contains).reversed().compactMap { ledger.release(key: $0) }
    }

    /// Presses for modifiers `flags` says are down that the remote doesn't hold (one pressed
    /// before capture began, its press gone to the Mac).
    private mutating func pressMissingModifiers(_ flags: UInt) -> [InputMessage] {
        let held = Set(ledger.heldKeys)
        return MacKeyTranslator.modifiersDown(flags, holding: held).filter { !held.contains($0) }
            .flatMap { ledger.press(key: $0) }
    }

    public mutating func pointer(_ event: PointerEvent) -> InputResult {
        if let stray = strayUp, case .button(stray, let pressed, _, _) = event {
            strayUp = nil
            if !pressed { return InputResult(consumed: true) }
        }
        if let held = recapturingButton {
            switch event {
            // A fresh press of it: its up was missed.
            case .button(held, pressed: true, _, _): recapturingButton = nil
            // Its up moves the remote pointer to where it was let go, so keys typed next go
            // where the Mac's pointer is.
            case .button(held, pressed: false, let x, let y):
                recapturingButton = nil
                return InputResult(consumed: true, messages: move(x, y))
            default: return InputResult(consumed: true)
            }
        }
        guard capture.isCaptured else {
            guard case .button(let number, pressed: true, _, _) = event, capture.clickRecaptures else {
                return InputResult()
            }
            recapturingButton = number
            var result = capture(.pictureClicked)
            result.consumed = true
            return result
        }
        let messages: [InputMessage]
        switch event {
        case .moved(let x, let y): return InputResult(consumed: true, messages: move(x, y))
        case .button(let number, let pressed, _, _):
            guard let code = PointerButtons.code(forButtonNumber: number) else {
                return InputResult(consumed: true)
            }
            messages = pressed ? ledger.press(button: code) : ledger.release(button: code).map { [$0] } ?? []
        case .scroll(let scroll, _, _):
            messages = ScrollTranslator.messages(for: scroll)
            for case .pointerAxis(let axis, _, nil, let stop) in messages {
                if stop { scrolling.remove(axis) } else { scrolling.insert(axis) }
            }
        }
        guard !messages.isEmpty else { return InputResult(consumed: true) }
        return InputResult(consumed: true, messages: move(event.position.x, event.position.y) + messages)
    }

    /// A motion to (x, y), unless the remote pointer is there already.
    private mutating func move(_ x: Double, _ y: Double) -> [InputMessage] {
        if let remoteAt, remoteAt == (x, y) { return [] }
        remoteAt = (x, y)
        return [.pointerMotion(x: x, y: y)]
    }

    public mutating func capture(_ event: CaptureEvent) -> InputResult {
        let showHint = capture.apply(event)
        // A recapturing click cut short (its up gone elsewhere, or never coming after sleep or
        // a lock) is forgotten.
        guard !capture.isCaptured || event == .away else { return InputResult(showHint: showHint) }
        if let held = recapturingButton { strayUp = held }
        recapturingButton = nil
        remoteAt = nil
        let stops = [Axis.vertical, .horizontal].filter(scrolling.contains).map {
            InputMessage.pointerAxis(axis: $0, value: 0, discrete: nil, stop: true)
        }
        scrolling = []
        let releases = stops + ledger.releaseAll()
        return InputResult(messages: releases, showHint: showHint)
    }
}
