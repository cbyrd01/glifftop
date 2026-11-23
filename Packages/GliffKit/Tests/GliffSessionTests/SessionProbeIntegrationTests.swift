#if os(macOS)
    import Synchronization
    import Testing

    import GliffTransport

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

        /// An unanswered probe means the link is dead: the session abandons its connection,
        /// which on a shared connection ends the link for everyone on it.
        @Test func anUnansweredProbeAbandonsTheConnection() async throws {
            let spy = try #require(AbandonSpy(["stall", "20000"]))
            let decoder = SpyDecoder()
            let session = Session(
                transport: spy, configuration: SessionConfiguration(maxWidth: 4096, maxHeight: 4096),
                decoder: decoder)
            let runner = Task { await session.run() }
            await decoder.waitFor(2)
            try? await Task.sleep(for: .milliseconds(500))
            session.probe()
            await runner.value
            #expect(spy.abandoned == 1)
        }

        @Test func aDisconnectClosesWithoutAbandoning() async throws {
            let spy = try #require(AbandonSpy(["stream", "--frames", "2", "--expect-bye"]))
            let decoder = SpyDecoder()
            let session = Session(
                transport: spy, configuration: SessionConfiguration(maxWidth: 4096, maxHeight: 4096),
                decoder: decoder)
            let runner = Task { await session.run() }
            await decoder.waitFor(1)
            await session.disconnect()
            await runner.value
            #expect(spy.abandoned == 0)
        }
    }

    /// The fake server's connection, counting `abandon()`s.
    final class AbandonSpy: Transport, ByteConnection {
        private let inner: ObservedTransport
        private let state = Mutex<(connection: (any ByteConnection)?, abandoned: Int)>((nil, 0))

        init?(_ args: [String]) {
            guard let inner = ObservedTransport(args) else { return nil }
            self.inner = inner
        }

        var abandoned: Int { state.withLock { $0.abandoned } }
        private var connection: any ByteConnection { state.withLock { $0.connection }! }

        func connect() async throws(TransportError) -> any ByteConnection {
            let connection = try await inner.connect()
            state.withLock { $0.connection = connection }
            return self
        }

        var incoming: AsyncThrowingStream<[UInt8], any Error> { connection.incoming }
        func write(_ bytes: [UInt8]) async throws(TransportError) { try await connection.write(bytes) }
        func close() async { await connection.close() }
        func abandon() async {
            state.withLock { $0.abandoned += 1 }
            await connection.close()
        }
    }
#endif
