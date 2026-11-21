import GliffProtocol
import Testing

@testable import GliffSession

/// Clipboard messages reach the bridge once the handshake is done.
@Suite struct SessionCoreClipboardTests {
    private let message = ClipboardMessage.abort(id: 3)

    @Test func clipboardIsRoutedWhileStreaming() {
        var core = HandshakeTests.core()
        _ = core.receive(HandshakeTests.helloAck(), payloadLength: 0, now: 0)
        #expect(core.receive(.clipboard(message), payloadLength: 0, now: 0) == [.clipboard(message)])
        _ = core.receive(.streamConfig(HandshakeTests.config), payloadLength: 0, now: 0)
        #expect(core.receive(.clipboard(message), payloadLength: 0, now: 0) == [.clipboard(message)])
    }

    @Test func clipboardIsIgnoredBeforeHelloAck() {
        var core = HandshakeTests.core()
        #expect(core.receive(.clipboard(message), payloadLength: 0, now: 0) == [])
        #expect(!core.isFinished)
    }
}
