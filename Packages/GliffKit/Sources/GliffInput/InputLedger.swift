/// What the remote has seen pressed, keys and pointer buttons alike, so nothing is left down
/// there: a release is sent only for what is held (a key-up whose key-down went elsewhere is
/// dropped), a fresh press of something still held first releases it (its release was
/// missed), and `releaseAll()` lets go of everything at once, for every way input can leave.
public struct InputLedger: Sendable {
    /// The keys held, in the order they were pressed.
    public private(set) var heldKeys: [UInt32] = []
    /// The pointer buttons held, in the order they were pressed.
    public private(set) var heldButtons: [UInt32] = []

    public init() {}

    /// The press to send. A key already held lost its key-up somewhere (callers drop
    /// auto-repeats first), so the remote is told to let go of it before the new press.
    public mutating func press(key: UInt32) -> [InputMessage] {
        Self.press(key, in: &heldKeys) { .key(code: $0, pressed: $1) }
    }

    /// The release to send, or nil when the key isn't held.
    public mutating func release(key: UInt32) -> InputMessage? {
        Self.release(key, in: &heldKeys) { .key(code: $0, pressed: $1) }
    }

    /// As `press(key:)`, for a pointer button.
    public mutating func press(button: UInt32) -> [InputMessage] {
        Self.press(button, in: &heldButtons) { .pointerButton(code: $0, pressed: $1) }
    }

    /// As `release(key:)`, for a pointer button.
    public mutating func release(button: UInt32) -> InputMessage? {
        Self.release(button, in: &heldButtons) { .pointerButton(code: $0, pressed: $1) }
    }

    /// Releases for every held button, then every held key, each last pressed first (⌘W lets
    /// go of W, then ⌘).
    public mutating func releaseAll() -> [InputMessage] {
        let buttons = heldButtons.reversed().map { InputMessage.pointerButton(code: $0, pressed: false) }
        heldButtons.removeAll()
        return buttons + releaseAllKeys()
    }

    /// Releases for every held key, last pressed first; buttons stay held.
    public mutating func releaseAllKeys() -> [InputMessage] {
        defer { heldKeys.removeAll() }
        return heldKeys.reversed().map { .key(code: $0, pressed: false) }
    }

    private static func press(
        _ code: UInt32, in held: inout [UInt32], _ message: (UInt32, Bool) -> InputMessage
    ) -> [InputMessage] {
        let missed = release(code, in: &held, message)
        held.append(code)
        return (missed.map { [$0] } ?? []) + [message(code, true)]
    }

    private static func release(
        _ code: UInt32, in held: inout [UInt32], _ message: (UInt32, Bool) -> InputMessage
    ) -> InputMessage? {
        guard let index = held.firstIndex(of: code) else { return nil }
        held.remove(at: index)
        return message(code, false)
    }
}
