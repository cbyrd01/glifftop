/// The sender's flow control (upstream's `SendWindow`): at most `ClipboardLimits.window` chunks
/// sent and not yet acked, however small.
public struct SendWindow: Sendable {
    public private(set) var offset: UInt64 = 0
    /// The end offset of each chunk sent and not yet acked, in order.
    private var unacked: [UInt64] = []

    public init() {}

    public var maySend: Bool { unacked.count < ClipboardLimits.window }

    public mutating func onSent(_ length: Int) {
        offset += UInt64(length)
        unacked.append(offset)
    }

    public mutating func onAck(_ received: UInt64) throws(ChunkError) {
        guard received <= offset else { throw .badAck(received) }
        unacked.removeAll { $0 <= received }
    }
}
