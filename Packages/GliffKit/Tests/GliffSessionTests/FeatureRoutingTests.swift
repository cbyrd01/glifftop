import GliffProtocol
import Testing

@testable import GliffSession

/// Unknown server variants go to the feature that claims them, once the server echoed it.
@Suite struct FeatureRoutingTests {
    private func core(echoed: [String]) -> SessionCore {
        var core = HandshakeTests.core(features: ["test": [99]])
        _ = core.receive(HandshakeTests.helloAck(features: echoed), payloadLength: 0, now: 0)
        return core
    }

    @Test func claimedVariantIsDelivered() {
        var core = core(echoed: ["test"])
        #expect(core.receive(.unknown(variant: 99), payloadLength: 3, now: 0) == [.deliver(feature: "test")])
    }

    @Test func notEchoedIsSkipped() {
        var core = core(echoed: [])
        #expect(core.receive(.unknown(variant: 99), payloadLength: 3, now: 0) == [])
    }

    @Test func unclaimedVariantIsSkipped() {
        var core = core(echoed: ["test"])
        #expect(core.receive(.unknown(variant: 98), payloadLength: 2, now: 0) == [])
    }

    /// Delivery doesn't wait for video: a feature may talk before the first StreamConfig.
    @Test func deliveredWhileStreamingToo() {
        var core = core(echoed: ["test"])
        _ = core.receive(.streamConfig(HandshakeTests.config), payloadLength: 0, now: 0)
        #expect(core.receive(.unknown(variant: 99), payloadLength: 3, now: 0) == [.deliver(feature: "test")])
    }
}
