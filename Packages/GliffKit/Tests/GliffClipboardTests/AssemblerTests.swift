import GliffClipboard
import Testing

@Suite struct AssemblerTests {
    @Test func inOrderChunksWithDone() throws {
        var assembler = Assembler(cap: nil)
        try assembler.accept(offset: 0, length: 5, done: false)
        try assembler.accept(offset: 5, length: 3, done: true)
        #expect(assembler.received == 8)
        #expect(assembler.done)
    }

    @Test func anEmptyFinalChunk() throws {
        var assembler = Assembler(cap: 0)
        try assembler.accept(offset: 0, length: 0, done: true)
        #expect(assembler.received == 0)
        #expect(assembler.done)
    }

    @Test func aGapIsBadOffset() throws {
        var assembler = Assembler(cap: nil)
        try assembler.accept(offset: 0, length: 5, done: false)
        #expect(throws: ChunkError.badOffset(expected: 5, got: 6)) {
            try assembler.accept(offset: 6, length: 1, done: false)
        }
    }

    @Test func aChunkOver256KiB() {
        var assembler = Assembler(cap: nil)
        #expect(throws: ChunkError.chunkTooLarge(262_145)) {
            try assembler.accept(offset: 0, length: 262_145, done: false)
        }
    }

    @Test func aChunkOfExactly256KiB() throws {
        var assembler = Assembler(cap: nil)
        try assembler.accept(offset: 0, length: 262_144, done: false)
    }

    @Test func overTheCap() throws {
        var assembler = Assembler(cap: 10)
        try assembler.accept(offset: 0, length: 6, done: false)
        #expect(throws: ChunkError.overCap(10)) { try assembler.accept(offset: 6, length: 5, done: false) }
    }

    @Test func afterDone() throws {
        var assembler = Assembler(cap: nil)
        try assembler.accept(offset: 0, length: 1, done: true)
        #expect(throws: ChunkError.afterDone) { try assembler.accept(offset: 1, length: 1, done: false) }
    }
}
