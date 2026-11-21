// Gliff protocol v1 constants. Source of truth: upstream gliff-proto `msg.rs` at v0.4.3.

/// Protocol-wide constants exchanged in the handshake.
public enum GliffProtocol {
    /// The protocol version this client speaks (`PROTOCOL_VERSION`).
    public static let version: UInt16 = 1
    /// Optional features this client advertises (`FEATURES`); none in v1.
    public static let features: [String] = []
}

/// `ServerMessage.error` codes.
public enum ErrorCode {
    public static let version: UInt16 = 1
    public static let noChroma: UInt16 = 2
    public static let noCodec: UInt16 = 3
    /// The server could not start the session. Outside the incompatible range, so a
    /// reconnect may succeed.
    public static let setup: UInt16 = 256

    /// Codes 1 to 255 mean the two ends cannot work together, so reconnecting would fail
    /// the same way. A new code in that range is fatal even if this client predates it.
    public static func isIncompatible(_ code: UInt16) -> Bool {
        (1..<256).contains(code)
    }
}
