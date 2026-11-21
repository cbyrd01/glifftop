import Synchronization

/// Where a transfer's bytes come from: an empty read means the end.
public protocol ChunkSource: Sendable {
    func read(upTo count: Int) async throws -> [UInt8]
}

/// Where a fetched item's bytes go; `finish` once the last chunk is written.
public protocol ChunkSink: Sendable {
    func write(_ bytes: [UInt8]) async throws
    func finish() async throws
}

/// An item already in memory.
public final class MemorySource: ChunkSource {
    private let state: Mutex<(bytes: [UInt8], offset: Int)>

    public init(_ bytes: [UInt8]) { state = Mutex((bytes, 0)) }

    public func read(upTo count: Int) async throws -> [UInt8] {
        state.withLock { state in
            let end = state.offset + min(max(count, 0), state.bytes.count - state.offset)
            defer { state.offset = end }
            return Array(state.bytes[state.offset..<end])
        }
    }
}

public enum MemorySinkError: Error, Equatable, Sendable {
    case overCap(UInt64)
}

/// Collects an item in memory, refusing more than `cap` bytes.
public final class MemorySink: ChunkSink {
    private let cap: UInt64
    private let collected = Mutex<[UInt8]>([])

    public init(cap: UInt64) { self.cap = cap }

    public var bytes: [UInt8] { collected.withLock { $0 } }

    public func write(_ bytes: [UInt8]) async throws {
        try collected.withLock { collected throws(MemorySinkError) in
            guard UInt64(collected.count + bytes.count) <= cap else { throw .overCap(cap) }
            collected += bytes
        }
    }

    public func finish() async throws {}
}
