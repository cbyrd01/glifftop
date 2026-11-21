/// The receiver's check of chunk order and size, with an optional cap on the total (upstream's
/// `Assembler`).
public struct Assembler: Sendable {
    public private(set) var received: UInt64 = 0
    public private(set) var done = false
    private let cap: UInt64?

    public init(cap: UInt64?) { self.cap = cap }

    public mutating func accept(offset: UInt64, length: UInt32, done: Bool) throws(ChunkError) {
        guard !self.done else { throw .afterDone }
        guard offset == received else { throw .badOffset(expected: received, got: offset) }
        guard length <= ClipboardLimits.chunk else { throw .chunkTooLarge(length) }
        let next = received + UInt64(length)
        if let cap, next > cap { throw .overCap(cap) }
        received = next
        self.done = done
    }
}
