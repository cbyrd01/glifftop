/// The 8-byte header in front of every frame: little-endian `u32` body length, then `u32`
/// payload length. The body is a CBOR message; the payload is the raw bytes it declares
/// (video data, cursor pixels, a clipboard chunk). Upstream `frame.rs`: this layout never
/// changes, whatever the protocol version.
public struct FrameHeader: Equatable, Sendable {
    public static let size = 8
    /// Largest CBOR body either end sends or accepts.
    public static let maxBody: UInt32 = 1 << 20
    /// Largest single payload a message may declare (a keyframe).
    public static let maxPayload: UInt32 = 64 * 1024 * 1024
    /// Largest total payload of one frame: a keyframe's main and aux streams.
    public static let maxFramePayload: UInt32 = 2 * maxPayload

    public let bodyLength: UInt32
    public let payloadLength: UInt32

    /// Throws `bodyTooLarge` or `payloadTooLarge` (checked in that order, as upstream does)
    /// when a length is over its limit. Used for frames we send as well as frames we read.
    ///
    /// - This checks only the frame's total payload against `maxFramePayload`. The message
    ///   layer must also check each payload it declares against `maxPayload`, as upstream's
    ///   transport does.
    /// - Convert `Int` lengths with `UInt32(clamping:)`, so an oversized length throws here
    ///   instead of trapping in the conversion.
    public init(bodyLength: UInt32, payloadLength: UInt32) throws(ProtocolError) {
        guard bodyLength <= Self.maxBody else { throw ProtocolError.bodyTooLarge(bodyLength) }
        guard payloadLength <= Self.maxFramePayload else {
            throw ProtocolError.payloadTooLarge(payloadLength)
        }
        self.bodyLength = bodyLength
        self.payloadLength = payloadLength
    }

    /// Decodes the header from the first 8 bytes of `bytes`; `truncated` if there are fewer.
    /// The limits are checked before anything is allocated, so a peer that isn't speaking
    /// the protocol (a shell printing a banner) fails here.
    public init(decoding bytes: some Collection<UInt8>) throws(ProtocolError) {
        // The two little-endian u32s are one little-endian u64: body in the low half.
        var header: UInt64 = 0
        var count = 0
        for byte in bytes.prefix(Self.size) {
            header |= UInt64(byte) << (8 * count)
            count += 1
        }
        guard count == Self.size else { throw ProtocolError.truncated }
        try self.init(
            bodyLength: UInt32(truncatingIfNeeded: header),
            payloadLength: UInt32(truncatingIfNeeded: header >> 32)
        )
    }

    public var encoded: [UInt8] {
        let header = UInt64(payloadLength) << 32 | UInt64(bodyLength)
        return withUnsafeBytes(of: header.littleEndian, Array.init)
    }
}
