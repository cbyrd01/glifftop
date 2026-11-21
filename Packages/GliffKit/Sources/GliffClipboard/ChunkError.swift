/// A chunk or ack that breaks the transfer rules (upstream's `ChunkError`).
public enum ChunkError: Error, Equatable, Sendable {
    case badOffset(expected: UInt64, got: UInt64)
    case chunkTooLarge(UInt32)
    case overCap(UInt64)
    case afterDone
    case badAck(UInt64)
    case windowExceeded
}
