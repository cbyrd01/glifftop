import GliffClipboard
import Testing

@Suite struct SendWindowTests {
    @Test func fourChunksFillTheWindow() {
        var window = SendWindow()
        for _ in 0..<4 {
            #expect(window.maySend)
            window.onSent(10)
        }
        #expect(!window.maySend)
        #expect(window.offset == 40)
    }

    @Test func anAckReopensOne() throws {
        var window = SendWindow()
        for _ in 0..<4 { window.onSent(10) }
        try window.onAck(10)
        #expect(window.maySend)
        window.onSent(10)
        #expect(!window.maySend)
    }

    @Test func anAckMidChunkFreesNothing() throws {
        var window = SendWindow()
        for _ in 0..<4 { window.onSent(10) }
        try window.onAck(9)
        #expect(!window.maySend)
    }

    @Test func emptyChunksCountToo() {
        var window = SendWindow()
        for _ in 0..<4 { window.onSent(0) }
        #expect(!window.maySend)
    }

    @Test func anAckPastWhatWasSent() {
        var window = SendWindow()
        window.onSent(10)
        #expect(throws: ChunkError.badAck(11)) { try window.onAck(11) }
    }
}
