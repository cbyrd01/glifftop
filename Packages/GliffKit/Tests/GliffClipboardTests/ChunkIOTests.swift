import Foundation
import GliffClipboard
import Testing

@Suite struct ChunkIOTests {
    @Test func memorySourceInChunks() async throws {
        let source = MemorySource(pattern(600_000))
        var sizes: [Int] = []
        var all: [UInt8] = []
        while true {
            let chunk = try await source.read(upTo: 262_144)
            if chunk.isEmpty { break }
            sizes.append(chunk.count)
            all += chunk
        }
        #expect(sizes == [262_144, 262_144, 75_712])
        #expect(all == pattern(600_000))
    }

    @Test func memorySourceTakesAnyCount() async throws {
        let source = MemorySource([1, 2, 3])
        #expect(try await source.read(upTo: .max) == [1, 2, 3])
        #expect(try await source.read(upTo: .max) == [])
    }

    @Test func memorySinkCollects() async throws {
        let sink = MemorySink(cap: 10)
        try await sink.write([1, 2])
        try await sink.write([3])
        try await sink.finish()
        #expect(sink.bytes == [1, 2, 3])
    }

    @Test func memorySinkCap() async throws {
        let sink = MemorySink(cap: 10)
        try await sink.write(pattern(6))
        await #expect(throws: (any Error).self) { try await sink.write(pattern(5)) }
    }

    @Test func progressAddsUp() {
        let progress = TransferProgress()
        progress.add(4)
        progress.add(3)
        #expect(progress.done == 7)
    }
}
