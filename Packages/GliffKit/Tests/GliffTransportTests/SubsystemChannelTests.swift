import GliffTestSupport
import Testing

@testable import GliffTransport

/// A channel that asks the host for a subsystem (`sftp`) instead of running a command line.
@Suite struct SubsystemChannelTests {
    let hostClock = ManualClock()
    let clock = ManualClock()
    let opener = FakeOpener()
    let connections: HostConnections

    init() {
        connections = HostConnections(open: opener.open, clock: hostClock)
    }

    /// The subsystem form keeps every option the command form carries, then `-s`, and the
    /// subsystem's name where a command line would be.
    @Test func aSubsystemChannelAsksForSFTP() throws {
        let command = try SSHMasterCommand(
            target: SSHTarget("omarchy"), socket: "/s/1-1", sshArguments: ["-p", "2222"])
        #expect(
            command.subsystem("sftp")
                == ["-T", "-S", "/s/1-1"] + SSHMasterCommandTests.guards + [
                    "-o", "ClearAllForwardings=yes", "-p", "2222", "-s", "--", "omarchy", "sftp",
                ])
    }

    @Test func aSubsystemChannelIsReplayedOnAMove() async throws {
        let connection = try await ChannelTransport(
            connections: connections, target: SSHTarget("omarchy"), request: .subsystem("sftp"), clock: clock
        ).connect()
        try await connection.write([1, 2, 3])
        let first = try #require(opener.made.first?.channels.first)
        first.fail(.exited(status: 255, failure: .channelRefused))
        #expect(await eventually { opener.made.count == 2 && opener.made[1].channels.count == 1 })
        #expect(opener.made.map(\.requests) == [[.subsystem("sftp")], [.subsystem("sftp")]])
        let second = try #require(opener.made.last?.channels.first)
        #expect(await eventually { second.written == [1, 2, 3] })
        await connection.close()
    }

    @Test func aCommandChannelIsUnchanged() async throws {
        let connection = try await ChannelTransport(
            connections: connections, target: SSHTarget("omarchy"), command: "gliff-server --stdio",
            clock: clock
        ).connect()
        #expect(opener.made.first?.requests == [.command("gliff-server --stdio")])
        #expect(opener.made.first?.commands == ["gliff-server --stdio"])
        await connection.close()
    }
}
