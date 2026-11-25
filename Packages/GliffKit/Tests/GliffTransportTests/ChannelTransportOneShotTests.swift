import GliffTestSupport
import Testing

@testable import GliffTransport

/// `ChannelTransport` in its one-shot mode, as a start macro's: what it wrote is never run
/// twice. Only a channel sshd refused before any byte came back moves, once, to a connection
/// already open with room.
@Suite struct ChannelTransportOneShotTests {
    let hostClock = ManualClock()
    let clock = ManualClock()
    let opener = FakeOpener()

    func connections(leaseLimit: Int = 10) -> HostConnections {
        HostConnections(open: opener.open, clock: hostClock, leaseLimit: leaseLimit)
    }

    func oneShot(on connections: HostConnections, opening: Bool = true) throws -> ChannelTransport {
        try ChannelTransport(
            connections: connections, target: SSHTarget("omarchy"), command: "sh -s", oneShot: true,
            opening: opening, logsStderr: false, clock: clock)
    }

    func session(on connections: HostConnections) throws -> ChannelTransport {
        try ChannelTransport(
            connections: connections, target: SSHTarget("omarchy"), command: "gliff-server --stdio",
            clock: clock)
    }

    var channels: [FakeChannel] { opener.made.flatMap(\.channels) }
    static let refused = TransportError.exited(status: 255, failure: .channelRefused)
    static let lost = TransportError.exited(status: 255, failure: .sharedConnectionLost)

    /// Two connections: the one-shot alone on a full first one, the second open with room.
    func twoConnections() async throws -> any ByteConnection {
        let hosts = connections(leaseLimit: 1)
        let macro = try await oneShot(on: hosts).connect()
        let other = try await session(on: hosts).connect()
        await other.close()
        #expect(opener.calls == 2)
        return macro
    }

    @Test func oneShotLostMasterAfterWriteIsNotReplayed() async throws {
        let connection = try await oneShot(on: connections()).connect()
        try await connection.write([1, 2, 3])
        try #require(channels.first).fail(Self.lost)
        await #expect(throws: Self.lost) { for try await _ in connection.incoming {} }
        #expect(channels.count == 1)
        #expect(channels.first?.written == [1, 2, 3])
        #expect(opener.calls == 1)
    }

    @Test func oneShotRefusedMovesOnceToAnOpenConnection() async throws {
        let connection = try await twoConnections()
        try await connection.write([1, 2, 3])
        try #require(opener.made.first?.channels.first).fail(Self.refused)
        let moved = try #require(await movedChannel())
        #expect(await eventually { moved.written == [1, 2, 3] })
        moved.send([9])
        var chunks = connection.incoming.makeAsyncIterator()
        #expect(try await chunks.next() == [9])
        #expect(opener.calls == 2)
        #expect(opener.made.map(\.stderrLogged) == [[false], [true, false]])
    }

    @Test func oneShotRefusedWithNoOpenConnectionFails() async throws {
        let connection = try await oneShot(on: connections()).connect()
        try await connection.write([1])
        try #require(channels.first).fail(Self.refused)
        await #expect(throws: HostConnectionsOpeningTests.noRoom) {
            for try await _ in connection.incoming {}
        }
        #expect(opener.calls == 1)
        #expect(channels.count == 1)
    }

    @Test func oneShotRefusedTwiceFails() async throws {
        let connection = try await twoConnections()
        try await connection.write([1])
        try #require(opener.made.first?.channels.first).fail(Self.refused)
        let moved = try #require(await movedChannel())
        #expect(await eventually { moved.written == [1] })
        moved.fail(Self.refused)
        await #expect(throws: Self.refused) { for try await _ in connection.incoming {} }
        #expect(opener.calls == 2)
        #expect(channels.count == 3)
    }

    @Test func oneShotNeverMovesAfterTheFirstByte() async throws {
        let connection = try await twoConnections()
        let first = try #require(opener.made.first?.channels.first)
        first.send([7])
        first.fail(Self.refused)
        var received: [[UInt8]] = []
        await #expect(throws: Self.refused) {
            for try await chunk in connection.incoming { received.append(chunk) }
        }
        #expect(received == [[7]])
        #expect(channels.count == 2)
    }

    /// A first channel on a connection found lost fails: the one-shot never moves for it.
    @Test func oneShotFirstChannelOnADeadConnectionFails() async throws {
        let hosts = connections()
        _ = try await session(on: hosts).connect()
        try #require(opener.made.first).failNextChannel(Self.lost)
        await #expect(throws: Self.lost) { try await oneShot(on: hosts).connect() }
        #expect(opener.calls == 1)
    }

    @Test func oneShotNotOpeningWithNoConnectionFails() async throws {
        await #expect(throws: HostConnectionsOpeningTests.noRoom) {
            try await oneShot(on: connections(), opening: false).connect()
        }
        #expect(opener.calls == 0)
    }

    /// The channel the one-shot moved to: the second connection's newest.
    private func movedChannel() async -> FakeChannel? {
        guard await eventually({ opener.made.last?.channels.count == 2 }) else { return nil }
        return opener.made.last?.channels.last
    }
}
