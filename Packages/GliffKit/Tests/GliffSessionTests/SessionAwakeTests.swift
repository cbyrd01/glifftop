#if os(macOS)
    import GliffTransport
    import Synchronization
    import Testing

    @testable import GliffSession

    /// A running session keeps the app from being napped, so its frames are decoded and
    /// acknowledged on time with every window hidden.
    @Suite(.timeLimit(.minutes(1))) struct SessionAwakeTests {
        final class Counts: Sendable {
            let begun = Mutex(0)
            let ended = Mutex(0)
        }

        @Test func aRunningSessionHoldsTheAppAwakeUntilItEnds() async {
            let counts = Counts()
            let awake = Awake {
                counts.begun.withLock { $0 += 1 }
                return { counts.ended.withLock { $0 += 1 } }
            }
            let transport = SessionConnectingTests.SlowTransport()
            let session = Session(
                transport: transport, configuration: SessionConfiguration(maxWidth: 5120, maxHeight: 2880),
                decoder: SpyDecoder(), awake: awake)
            let runner = Task { await session.run() }
            for await _ in transport.started { break }
            #expect(counts.begun.withLock { $0 } == 1)
            #expect(counts.ended.withLock { $0 } == 0)
            await session.disconnect()
            await runner.value
            #expect(counts.begun.withLock { $0 } == 1)
            #expect(counts.ended.withLock { $0 } == 1)
        }

        @Test func aSessionDisconnectedBeforeItRunsNeverHoldsIt() async {
            let counts = Counts()
            let awake = Awake {
                counts.begun.withLock { $0 += 1 }
                return {}
            }
            let session = Session(
                transport: SessionConnectingTests.FailingTransport(),
                configuration: SessionConfiguration(maxWidth: 5120, maxHeight: 2880), decoder: SpyDecoder(),
                awake: awake)
            await session.disconnect()
            await session.run()
            #expect(counts.begun.withLock { $0 } == 0)
        }
    }
#endif
