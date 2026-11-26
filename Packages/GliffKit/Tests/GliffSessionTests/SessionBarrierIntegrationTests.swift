#if os(macOS)
    import GliffInput
    import GliffProtocol
    import GliffTestSupport
    import GliffVideo
    import Synchronization
    import Testing

    @testable import GliffSession

    /// The barrier between two sessions against `fake-server serve input`: one session's input
    /// waits for the other's modifier release to be answered by its server.
    extension SessionIntegrationTests {
        /// A's server answers each Ping 300 ms late. A pings first (a probe, as the stats'
        /// Pings), then lets go of Super: B's keys wait past the probe's Pong for the one behind
        /// the release, then `settle`, never the limit (the clock moves only by hand).
        @Test func anotherSessionsKeysWaitForTheReleasesAnswer() async throws {
            let clock = ManualClock()
            let barrier = InputBarrier(clock: clock)
            let counter = RecordingObserver()
            let transport = try #require(ObservedTransport(["input", "--pong-delay", "300"]))
            let a = Session(
                transport: transport, configuration: SessionConfiguration(maxWidth: 4096, maxHeight: 4096),
                decoder: NullFrameDecoder(), observer: counter, barrier: barrier)
            let (b, bTransport) = try makeSession(["input", "--expect-keys", "2"], barrier: barrier)
            let runners = [Task { await a.run() }, Task { await b.run() }]
            let held = await b.inputs
            await Self.streaming(a)
            await Self.streaming(b)
            let pings = counter.count(.sent, "Ping")
            a.probe()
            #expect(await eventually { counter.count(.sent, "Ping") > pings })
            a.send(Self.press(125))
            a.send(Self.release(125))
            #expect(await eventually { counter.count(.sent, "Ping") > pings + 1 })
            b.send(Self.press(30))
            b.send(Self.release(30))
            // Every Pong but the last answers a Ping sent before the release.
            #expect(await eventually { counter.count(.received, "Pong") >= pings + 1 })
            #expect(!held.isEmpty)
            #expect(
                barrier.wait(before: Self.press(30), from: InputBarrier.Sender()).wait?.left
                    == InputBarrier.limit)
            #expect(
                await eventually {
                    barrier.wait(before: Self.press(30), from: InputBarrier.Sender()).wait?.left
                        == InputBarrier.settle
                })
            #expect(!held.isEmpty)
            clock.advance(by: InputBarrier.settle)
            #expect(await eventually { held.isEmpty })
            await a.disconnect()
            await b.disconnect()
            for runner in runners { await runner.value }
            #expect(transport.serverFailure == nil)
            #expect(bTransport.serverFailure == nil)
        }

        /// A's server queues each Pong 200 ms, as behind a frame being written, and drops one still
        /// queued when a newer one is, as upstream's writer does: the probe's Pong never comes.
        /// The Pong to the Ping behind the release answers the probe and the release, and B's keys go
        /// `settle` after it, never at the limit (the clock moves only by hand). The answer comes
        /// within 1 s of the release's Ping: the stats' next Ping, whose Pong would also answer
        /// it were Pongs counted, goes no sooner than `SessionCore.pingInterval` after it.
        @Test func aReleaseIsAnsweredThoughAnEarlierPongWasDropped() async throws {
            let clock = ManualClock()
            let barrier = InputBarrier(clock: clock)
            let counter = RecordingObserver()
            let transport = try #require(ObservedTransport(["input", "--coalesce-pongs", "200"]))
            let a = Session(
                transport: transport, configuration: SessionConfiguration(maxWidth: 4096, maxHeight: 4096),
                decoder: NullFrameDecoder(), observer: counter, barrier: barrier)
            let (b, bTransport) = try makeSession(["input", "--expect-keys", "2"], barrier: barrier)
            let runners = [Task { await a.run() }, Task { await b.run() }]
            let held = await b.inputs
            await Self.streaming(a)
            await Self.streaming(b)
            let before = (pings: counter.count(.sent, "Ping"), pongs: counter.count(.received, "Pong"))
            a.probe()
            #expect(await eventually { counter.count(.sent, "Ping") > before.pings })
            a.send(Self.press(125))
            a.send(Self.release(125))
            #expect(await eventually { counter.count(.sent, "Ping") > before.pings + 1 })
            b.send(Self.press(30))
            b.send(Self.release(30))
            #expect(
                await eventually(within: .seconds(1)) {
                    barrier.wait(before: Self.press(30), from: InputBarrier.Sender()).wait?.left
                        == InputBarrier.settle
                })
            let after = (pings: counter.count(.sent, "Ping"), pongs: counter.count(.received, "Pong"))
            #expect(after.pongs - before.pongs < after.pings - before.pings)
            #expect(await !a.liveness.isProbing)
            #expect(!held.isEmpty)
            clock.advance(by: InputBarrier.settle)
            #expect(await eventually { held.isEmpty })
            await a.disconnect()
            await b.disconnect()
            for runner in runners { await runner.value }
            #expect(transport.serverFailure == nil)
            #expect(bTransport.serverFailure == nil)
        }

        /// A probe sent in the millisecond after a release's Ping: each Ping's `t` is its own
        /// (`SessionCore.pingNow`), and the probe waits for the Pong to its own, not the
        /// release's, which the server (300 ms per Ping) answers first.
        @Test func aProbeWaitsForThePongToItsOwnPing() async throws {
            let counter = RecordingObserver()
            let transport = try #require(ObservedTransport(["input", "--pong-delay", "300"]))
            let a = Session(
                transport: transport, configuration: SessionConfiguration(maxWidth: 4096, maxHeight: 4096),
                decoder: NullFrameDecoder(), observer: counter, barrier: InputBarrier())
            let runner = Task { await a.run() }
            await Self.streaming(a)
            let pongs = counter.count(.received, "Pong")
            a.send(Self.press(125))
            a.send(Self.release(125))
            a.probe()
            #expect(await eventually { counter.count(.received, "Pong") > pongs })
            #expect(await a.liveness.isProbing)
            var probing = true
            for _ in 0..<500 where probing {
                try await Task.sleep(for: .milliseconds(10))
                probing = await a.liveness.isProbing
            }
            #expect(!probing)
            await a.disconnect()
            await runner.value
            #expect(transport.serverFailure == nil)
        }

        /// A closes as it lets go of Super (a tab closed with it held). Its server, answering each
        /// Ping 2.5 s late, never answers the Ping behind the release before it is ended, so the
        /// release is answered once A's connection has closed: B's keys go `settle` after,
        /// never at the limit (the clock moves only by hand).
        @Test func aClosingSessionsReleaseIsAnsweredOnceItHasClosed() async throws {
            let clock = ManualClock()
            let barrier = InputBarrier(clock: clock)
            let (a, _) = try makeSession(["input", "--pong-delay", "2500"], barrier: barrier)
            let runner = Task { await a.run() }
            await Self.streaming(a)
            a.send(Self.press(125))
            a.send(Self.release(125))
            #expect(
                barrier.wait(before: Self.press(30), from: InputBarrier.Sender()).wait?.left
                    == InputBarrier.limit)
            await a.disconnect()
            await runner.value
            #expect(
                await eventually {
                    barrier.wait(before: Self.press(30), from: InputBarrier.Sender()).wait?.left
                        == InputBarrier.settle
                })
        }

        /// Returns once `session` is streaming.
        private static func streaming(_ session: Session) async {
            for await status in session.status {
                if case .streaming = status { return }
            }
        }
    }
#endif
