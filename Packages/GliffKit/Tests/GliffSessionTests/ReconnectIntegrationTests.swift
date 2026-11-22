#if os(macOS)
    import Synchronization
    import Testing

    @testable import GliffSession

    /// A dropped link, tried again on the real clock against the fake server.
    @Suite(
        .enabled(if: FakeServer.isAvailable, "set GLIFFTOP_FAKE_SERVER (scripts/test.sh does)"),
        .timeLimit(.minutes(1)))
    struct ReconnectIntegrationTests {
        private let harness = SessionIntegrationTests()

        @Test func aDroppedLinkComesBack() async throws {
            let first = try await harness.session(["drop"])
            let end = try #require(first.end)
            #expect(end == .connectionLost)

            // Every session a try started, and its run, to end them after.
            let started = Mutex<[(Session, ObservedTransport, Task<Void, Never>)]>([])
            let harness = harness
            let reconnector = Reconnector {
                guard let (session, transport) = try? harness.makeSession(["stream", "--expect-bye"]) else {
                    return .ended(.disconnected)
                }
                let runner = Task { await session.run() }
                started.withLock { $0.append((session, transport, runner)) }
                return await withTaskCancellationHandler {
                    for await status in session.status {
                        switch status {
                        case .streaming: return .streaming
                        case .ended(let end): return .ended(end)
                        default: continue
                        }
                    }
                    return .ended(.connectionLost)
                } onCancel: {
                    Task { await session.disconnect() }
                }
            }

            let start = ContinuousClock.now
            #expect(await reconnector.run(after: end) == .reconnected)
            #expect(ContinuousClock.now - start < .seconds(10))

            let sessions = started.withLock { $0 }
            #expect(sessions.count == 1)
            for (session, transport, runner) in sessions {
                await session.disconnect()
                await runner.value
                #expect(transport.serverFailure == nil)
            }
        }
    }
#endif
