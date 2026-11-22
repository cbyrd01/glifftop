#if os(macOS)
    import GliffTransport
    import Synchronization
    import Testing

    @testable import GliffSession

    /// A Disconnect while the transport is still connecting cancels that connect, so ssh
    /// isn't started for a session already ended.
    @Suite(.timeLimit(.minutes(1))) struct SessionConnectingTests {
        /// Connects only once cancelled or after 10 s, and says which.
        final class SlowTransport: Transport {
            let started: AsyncStream<Void>
            private let startedContinuation: AsyncStream<Void>.Continuation
            private let cancelled = Mutex(false)

            init() { (started, startedContinuation) = AsyncStream.makeStream() }

            var wasCancelled: Bool { cancelled.withLock { $0 } }

            func connect() async throws(TransportError) -> any ByteConnection {
                startedContinuation.yield()
                try? await Task.sleep(for: .seconds(10))
                cancelled.withLock { $0 = Task.isCancelled }
                throw .cancelled
            }
        }

        @Test func aDisconnectCancelsTheConnect() async {
            let transport = SlowTransport()
            let session = Session(
                transport: transport, configuration: SessionConfiguration(maxWidth: 5120, maxHeight: 2880),
                decoder: SpyDecoder())
            let runner = Task { await session.run() }
            for await _ in transport.started { break }
            let asked = ContinuousClock.now
            await session.disconnect()
            await runner.value
            #expect(transport.wasCancelled)
            #expect(ContinuousClock.now - asked < .seconds(5))
        }
    }
#endif
