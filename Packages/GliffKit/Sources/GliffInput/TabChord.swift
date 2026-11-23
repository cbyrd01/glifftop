/// ⌘⇧[ and ⌘⇧]: the previous and next Glifftop tab, kept from the remote while captured.
public enum TabChord: Equatable, Sendable {
    case previous, next

    private static let leftBracket: UInt16 = 33
    private static let rightBracket: UInt16 = 30

    /// The chord's key-down, with ⌘⇧ and no ⌃ or ⌥: held, it moves once.
    public init?(_ event: MacKeyEvent) {
        guard event.kind == .down(isRepeat: false), Self.chordFlags(event.flags) else { return nil }
        switch event.keyCode {
        case Self.leftBracket: self = .previous
        case Self.rightBracket: self = .next
        default: return nil
        }
    }

    /// The chord's key-up, or a repeat: swallowed too, so the remote never sees half of it.
    public static func isChordKey(_ event: MacKeyEvent) -> Bool {
        guard [leftBracket, rightBracket].contains(event.keyCode), chordFlags(event.flags) else {
            return false
        }
        return event.kind == .up || event.kind == .down(isRepeat: true)
    }

    private static func chordFlags(_ raw: UInt) -> Bool {
        let flags = MacModifierFlags(rawValue: raw)
        return flags.isSuperset(of: [.command, .shift]) && flags.isDisjoint(with: [.control, .option])
    }
}
