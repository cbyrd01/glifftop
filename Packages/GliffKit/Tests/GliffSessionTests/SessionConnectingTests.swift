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

        /// Fails its connect as a shared connection's sign-in does.
        struct FailingTransport: Transport {
            func connect() async throws(TransportError) -> any ByteConnection {
                throw .exited(status: 255, failure: .hostKeyUnchecked)
            }
        }

        /// A connect that fails ends the session as a failure to connect, with ssh's reason.
        @Test func aFailedConnectEndsWithItsReason() async {
            let session = Session(
                transport: FailingTransport(),
                configuration: SessionConfiguration(maxWidth: 5120, maxHeight: 2880), decoder: SpyDecoder())
            let runner = Task { await session.run() }
            var end: SessionEnd?
            for await status in session.status {
                if case .ended(let ended) = status {
                    end = ended
                    break
                }
            }
            await runner.value
            #expect(end == .connectFailed(.hostKeyUnchecked))
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
