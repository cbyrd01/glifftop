import GliffTestSupport
import Testing

@testable import GliffTransport

@Suite struct ChannelTransportTests {
    let hostClock = ManualClock()
    let clock = ManualClock()
    let opener = FakeOpener()
    let connections: HostConnections

    init() {
        connections = HostConnections(open: opener.open, clock: hostClock)
    }

    func transport() throws -> ChannelTransport {
        try ChannelTransport(
            connections: connections, target: SSHTarget("omarchy"), command: "gliff-server --stdio",
            clock: clock)
    }

    /// The channels handed out so far, oldest first, across every connection.
    var channels: [FakeChannel] { opener.made.flatMap(\.channels) }

    @Test func connectLeasesAndOpensTheCommand() async throws {
        _ = try await transport().connect()
        #expect(opener.calls == 1)
        #expect(opener.made.first?.commands == ["gliff-server --stdio"])
    }

    @Test func closingEndsTheLease() async throws {
        let connection = try await transport().connect()
        await connection.close()
        #expect(channels.first?.isClosed == true)
        #expect(await hostClock.waitForSleepers(1))
        hostClock.advance(by: .seconds(10))
        #expect(await eventually { opener.made.first?.closeCount == 1 })
    }

    @Test func aChannelRefusedBeforeItsFirstByteIsReplayed() async throws {
        let connection = try await transport().connect()
        try await connection.write([1, 2, 3])
        let first = try #require(channels.first)
        first.fail(.exited(status: 255, failure: .channelRefused))
        #expect(await eventually { channels.count == 2 })
        let second = try #require(channels.last)
        #expect(await eventually { second.written == [1, 2, 3] })
        #expect(opener.calls == 2)
        #expect(first.isClosed)
        try await connection.write([4])
        #expect(await eventually { second.written == [1, 2, 3, 4] })
        second.send([9])
        second.fail(.exited(status: 1, failure: .other("done")))
        var received: [[UInt8]] = []
        await #expect(throws: TransportError.exited(status: 1, failure: .other("done"))) {
            for try await chunk in connection.incoming { received.append(chunk) }
        }
        #expect(received == [[9]])
    }

    @Test func aRefusalAfterTheFirstByteIsAnError() async throws {
        let connection = try await transport().connect()
        let first = try #require(channels.first)
        first.send([7])
        let refused = TransportError.exited(status: 255, failure: .channelRefused)
        first.fail(refused)
        var received: [[UInt8]] = []
        await #expect(throws: refused) {
            for try await chunk in connection.incoming { received.append(chunk) }
        }
        #expect(received == [[7]])
        #expect(opener.calls == 1)
    }

    @Test func aChannelSilentForFifteenSecondsInvalidates() async throws {
        _ = try await transport().connect()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(15))
        #expect(await eventually { opener.made.first?.invalidateCount == 1 })
    }

    @Test func aByteBeforeFifteenSecondsInvalidatesNothing() async throws {
        let connection = try await transport().connect()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(14))
        try #require(channels.first).send([1])
        var chunks = connection.incoming.makeAsyncIterator()
        #expect(try await chunks.next() == [1])
        clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(50))
        #expect(opener.made.first?.invalidateCount == 0)
    }

    @Test func cancelledWhileLeasingThrowsCancelled() async throws {
        let transport = try transport()
        opener.hold()
        let connecting = Task { try await transport.connect() }
        #expect(await eventually { opener.waitingCount == 1 })
        connecting.cancel()
        await #expect(throws: TransportError.cancelled) { try await connecting.value }
        opener.release()
    }

    @Test func closingDuringAReplayClosesEveryChannel() async throws {
        let connection = try await transport().connect()
        opener.hold()
        try #require(channels.first).fail(.exited(status: 255, failure: .channelRefused))
        #expect(await eventually { opener.waitingCount == 1 })
        await connection.close()
        opener.release()
        #expect(await eventually { opener.made.count == 2 })
        var chunks = connection.incoming.makeAsyncIterator()
        #expect(try await chunks.next() == nil)
        #expect(channels.count == 1)
        #expect(channels.allSatisfy { $0.isClosed })
    }

    /// Disconnect while the move waits for a new connection (a sign-in prompt, say): nobody
    /// waits for that open any more, so it is dropped.
    @Test func closingDuringAMoveDropsItsOpen() async throws {
        let connection = try await transport().connect()
        opener.hold()
        try #require(channels.first).fail(.exited(status: 255, failure: .channelRefused))
        #expect(await eventually { opener.waitingCount == 1 })
        await connection.close()
        #expect(await hostClock.waitForSleepers(2))
        hostClock.advance(by: .seconds(1))
        #expect(await eventually { opener.cancelledCount == 1 })
        opener.release()
    }

    /// The watchdog moved a silent channel; the replayed one then fails for a reason of its own,
    /// which is what the session hears.
    @Test func aReplayedChannelsOwnFailureIsReported() async throws {
        let connection = try await transport().connect()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(15))
        #expect(await eventually { opener.made.first?.invalidateCount == 1 })
        try #require(channels.first).fail(.exited(status: 255, failure: .other("ssh exited with status 255")))
        #expect(await eventually { channels.count == 2 })
        let denied = TransportError.exited(status: 255, failure: .permissionDenied)
        try #require(channels.last).fail(denied)
        await #expect(throws: denied) {
            for try await _ in connection.incoming {}
        }
    }

    @Test func aSecondRefusalEndsTheStream() async throws {
        let connection = try await transport().connect()
        let refused = TransportError.exited(status: 255, failure: .channelRefused)
        try #require(channels.first).fail(refused)
        #expect(await eventually { channels.count == 2 })
        try #require(channels.last).fail(refused)
        await #expect(throws: refused) {
            for try await _ in connection.incoming {}
        }
        #expect(opener.calls == 2)
    }

    @Test func aReplayWhoseWriteFailsClosesItsChannel() async throws {
        let connection = try await transport().connect()
        try await connection.write([1])
        opener.failChannelWrites()
        try #require(channels.first).fail(.exited(status: 255, failure: .channelRefused))
        await #expect(throws: TransportError.writeFailed("broken pipe")) {
            for try await _ in connection.incoming {}
        }
        #expect(channels.count == 2)
        #expect(channels.allSatisfy { $0.isClosed })
    }

    @Test func aSilentChannelBesideALiveOneInvalidatesNothing() async throws {
        let streaming = try await transport().connect()
        let first = try #require(channels.first)
        first.send([1])
        var chunks = streaming.incoming.makeAsyncIterator()
        _ = try await chunks.next()
        #expect(await clock.waitForSleepers(0))
        _ = try await transport().connect()
        #expect(await clock.waitForSleepers(1))
        first.send([2])
        _ = try await chunks.next()
        clock.advance(by: .seconds(15))
        try await Task.sleep(for: .milliseconds(50))
        #expect(opener.made.first?.invalidateCount == 0)
    }

    /// A link found dead before the first byte is tried once more on a new connection; dead
    /// there too, it ends as a shared connection lost.
    @Test func aLinkFoundDeadEndsAsASharedConnectionLost() async throws {
        let connection = try await transport().connect()
        for made in 1...2 {
            #expect(await clock.waitForSleepers(1))
            clock.advance(by: .seconds(15))
            #expect(await eventually { opener.made.count == made && opener.made.last?.invalidateCount == 1 })
            try #require(channels.last).fail(
                .exited(status: 255, failure: .other("ssh exited with status 255")))
        }
        await #expect(throws: TransportError.exited(status: 255, failure: .sharedConnectionLost)) {
            for try await _ in connection.incoming {}
        }
        #expect(opener.calls == 2)
    }

    /// A session started on a connection whose master just died (after a wake, say) tries a
    /// new one rather than failing.
    @Test func aChannelOnADeadConnectionIsReplayed() async throws {
        let connection = try await transport().connect()
        try await connection.write([1, 2, 3])
        try #require(channels.first).fail(.exited(status: 255, failure: .sharedConnectionLost))
        #expect(await eventually { channels.count == 2 })
        let second = try #require(channels.last)
        #expect(await eventually { second.written == [1, 2, 3] })
        second.send([9])
        var chunks = connection.incoming.makeAsyncIterator()
        #expect(try await chunks.next() == [9])
    }

    /// A session found its link dead (an unanswered probe), and nothing else on the connection
    /// was heard from since this channel's last byte: the connection goes too.
    @Test func abandoningAQuietLinkInvalidates() async throws {
        let connection = try await transport().connect()
        try #require(channels.first).send([1])
        var chunks = connection.incoming.makeAsyncIterator()
        _ = try await chunks.next()
        await connection.abandon()
        #expect(opener.made.first?.invalidateCount == 1)
        #expect(channels.first?.isClosed == true)
    }

    /// Another channel was heard from after this one fell silent: its server hung, not the link.
    @Test func abandoningBesideALiveChannelInvalidatesNothing() async throws {
        let hung = try await transport().connect()
        let live = try await transport().connect()
        try #require(channels.first).send([1])
        var hungChunks = hung.incoming.makeAsyncIterator()
        _ = try await hungChunks.next()
        try #require(channels.last).send([2])
        var liveChunks = live.incoming.makeAsyncIterator()
        _ = try await liveChunks.next()
        await hung.abandon()
        #expect(opener.made.first?.invalidateCount == 0)
        #expect(channels.first?.isClosed == true)
    }

    /// An attempt the person starts asks for the sign-in again, whatever failed just before.
    @Test func aFreshTransportAsksAgain() async throws {
        let target = try SSHTarget("omarchy")
        opener.failNext(.exited(status: 255, failure: .agentRefused))
        await #expect(throws: TransportError.self) { try await transport().connect() }
        await #expect(throws: TransportError.self) { try await transport().connect() }
        #expect(opener.calls == 1)
        _ = try await ChannelTransport(
            connections: connections, target: target, command: "gliff-server --stdio", fresh: true,
            clock: clock
        ).connect()
        #expect(opener.calls == 2)
    }
}
