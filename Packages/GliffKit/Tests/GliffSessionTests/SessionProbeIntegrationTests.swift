#if os(macOS)
    import Testing

    @testable import GliffSession

    /// The probe after a wake, against the fake server. Both servers answer a Ping while
    /// waiting for acks, so each test probes once its frames are decoded.
    @Suite(
        .enabled(if: FakeServer.isAvailable, "set GLIFFTOP_FAKE_SERVER (scripts/test.sh does)"),
        .timeLimit(.minutes(1)))
    struct SessionProbeIntegrationTests {
        private let harness = SessionIntegrationTests()

        /// `stall` reads nothing once both frames are acked: the probe's Ping goes unanswered.
        @Test func anUnansweredProbeEndsTheSession() async throws {
            let decoder = SpyDecoder()
            let outcome = try await harness.session(
                ["stall", "20000"], decoder: decoder,
                drive: { session in
                    await decoder.waitFor(2)
                    // Room for the second ack to go out ahead of the Ping.
                    try? await Task.sleep(for: .milliseconds(500))
                    session.probe()
                    // Only a probe that never failed gets this far: it ends .disconnected.
                    try? await Task.sleep(for: .seconds(10))
                    await session.disconnect()
                })
            #expect(outcome.end == .connectionLost)
        }

        /// `stream` answers each Ping until Bye.
        @Test func anAnsweredProbeKeepsTheSession() async throws {
            let decoder = SpyDecoder()
            let outcome = try await harness.session(
                ["stream", "--frames", "2", "--expect-bye"], decoder: decoder,
                drive: { session in
                    await decoder.waitFor(1)
                    session.probe()
                    // Outlive the probe's 3 s.
                    try? await Task.sleep(for: .milliseconds(4500))
                    await session.disconnect()
                })
            #expect(outcome.end == .disconnected)
            #expect(outcome.serverFailure == nil)
        }
    }
#endif
