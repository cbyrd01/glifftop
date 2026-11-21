/// Why a transfer ended early, in words a person can read. Never a raw error.
public enum TransferError: Error, Equatable, Sendable {
    /// The peer sent `Abort`.
    case aborted
    /// The copy changed before the paste got it.
    case replaced
    case connectionEnded
    /// No chunk for `ClipboardLimits.idleTimeout`.
    case timedOut
    case cancelled
    /// Over the item's cap.
    case tooLarge
    /// The peer broke the transfer rules.
    case invalid
    /// Reading or writing failed here.
    case failed

    public var message: String {
        switch self {
        case .aborted: "The remote cancelled the transfer."
        case .replaced: "The copy was replaced before it could be pasted."
        case .connectionEnded: "The connection ended."
        case .timedOut: "The transfer stalled."
        case .cancelled: "Cancelled."
        case .tooLarge: "It's too large to paste (over 32 MB)."
        case .invalid: "The remote sent something unexpected."
        case .failed: "It couldn't be read or written."
        }
    }
}
