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

    @Test func aLinkFoundDeadEndsAsASharedConnectionLost() async throws {
        let connection = try await transport().connect()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(15))
        #expect(await eventually { opener.made.first?.invalidateCount == 1 })
        try #require(channels.first).fail(.exited(status: 255, failure: .other("ssh exited with status 255")))
        await #expect(throws: TransportError.exited(status: 255, failure: .sharedConnectionLost)) {
            for try await _ in connection.incoming {}
        }
    }
}
