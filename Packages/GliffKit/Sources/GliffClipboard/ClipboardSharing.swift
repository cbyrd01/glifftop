/// Share the clipboard, one setting of three: not shared, shared, or shared including passwords
/// (copies a password manager marks as concealed). Settings holds one, and a machine may hold
/// its own.
public enum ClipboardSharing: Int, CaseIterable, Codable, Sendable {
    /// In order of what's sent: each sends more than the one before.
    case off, shared, withPasswords

    /// From the two stored switches: Not Shared whenever sharing is off, so sharing again
    /// never brings passwords back unasked.
    public init(share: Bool, includePasswords: Bool) {
        self = !share ? .off : includePasswords ? .withPasswords : .shared
    }

    /// The setting a click on the toolbar's button moves to.
    public var next: ClipboardSharing {
        switch self {
        case .off: .shared
        case .shared: .withPasswords
        case .withPasswords: .off
        }
    }

    /// Whether moving to `level` sends more, and so asks first.
    public func sendsLess(than level: ClipboardSharing) -> Bool { rawValue < level.rawValue }
}
