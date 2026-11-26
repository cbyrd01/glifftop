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

    private static func chordFlags(_ raw: UInt) -> Bool {
        let flags = MacModifierFlags(rawValue: raw)
        return flags.isSuperset(of: [.command, .shift]) && flags.isDisjoint(with: [.control, .option])
    }
}

/// The chord's keys as they come: the chord's key-down, then its repeats and key-up, all kept
/// from the remote. Only the key whose press made a chord is kept: a bracket pressed before ⌘⇧
/// went to the remote, and its release goes there too.
public struct TabChordKeys: Sendable {
    public enum Outcome: Equatable, Sendable {
        case chord(TabChord)
        /// The chord's repeat or key-up.
        case swallowed
        /// Not the chord's: the remote's, while captured.
        case passed
    }

    /// The keys whose press made a chord, until their key-up. A new press of one passes: its
    /// key-up went to another window, and this one is the remote's.
    private var held = MacChordKeys()

    public init() {}

    public mutating func take(_ event: MacKeyEvent) -> Outcome {
        if let chord = TabChord(event) {
            held.hold(event.keyCode)
            return .chord(chord)
        }
        return held.take(event) ? .swallowed : .passed
    }
}
