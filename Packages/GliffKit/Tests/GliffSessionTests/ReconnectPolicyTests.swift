import GliffSession
import GliffTransport
import Testing

struct ReconnectPolicyTests {
    @Test func delaysDoubleFromOneToSixteen() {
        var policy = ReconnectPolicy()
        let delays = (0..<6).map { _ in policy.next(after: .connectionLost) }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), nil])
    }

    @Test(arguments: [
        SessionEnd.disconnected, .connectFailed(.permissionDenied),
        .connectFailed(.changedHostKey(fingerprint: nil, knownHostsName: nil)),
        .connectFailed(.hostKeyDenied), .connectFailed(.signInCancelled), .connectFailed(.tooManyQuestions),
        .connectFailed(.serverNotInstalled), .remoteNotGliff, .incompatible("x"), .protocolError("x"),
        .decoderFailed("x"),
    ])
    func anEndThatMayNotReconnectNeverRetries(_ end: SessionEnd) {
        var policy = ReconnectPolicy()
        #expect(policy.next(after: end) == nil)
        #expect(policy.failures == 0)
    }

    @Test(arguments: [
        SessionEnd.connectionLost, .serverSetupFailed("x"), .serverError(code: 300, message: "x"),
        .connectFailed(.unreachable), .connectFailed(.channelRefused), .connectFailed(.sharedConnectionLost),
    ])
    func anEndThatMayReconnectRetries(_ end: SessionEnd) {
        var policy = ReconnectPolicy()
        #expect(policy.next(after: end) == .seconds(1))
    }

    /// After a wake or a network change, DNS or the host's sshd may still be coming back.
    @Test(arguments: [ConnectFailure.hostNotFound, .connectionRefused])
    func aPassingConnectFailureRetriesOnARetry(_ failure: ConnectFailure) {
        var policy = ReconnectPolicy()
        _ = policy.next(after: .connectionLost)
        #expect(policy.next(after: .connectFailed(failure)) == .seconds(2))
    }

    /// A host that was never reached (a typo) isn't tried again.
    @Test(arguments: [ConnectFailure.hostNotFound, .connectionRefused, .other("x")])
    func aConnectFailureFirstNeverRetries(_ failure: ConnectFailure) {
        var policy = ReconnectPolicy()
        #expect(policy.next(after: .connectFailed(failure)) == nil)
    }

    @Test func anUnknownConnectFailureNeverRetries() {
        var policy = ReconnectPolicy()
        _ = policy.next(after: .connectionLost)
        #expect(policy.next(after: .connectFailed(.other("x"))) == nil)
    }

    @Test func givingUpStartsOver() {
        var policy = ReconnectPolicy()
        for _ in 0..<5 { _ = policy.next(after: .connectionLost) }
        #expect(policy.next(after: .connectionLost) == nil)
        #expect(policy.next(after: .connectionLost) == .seconds(1))
    }
}
