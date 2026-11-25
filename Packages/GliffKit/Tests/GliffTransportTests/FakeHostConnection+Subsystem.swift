@testable import GliffTransport

/// A subsystem channel on a `FakeHostConnection`: an ordinary `FakeChannel`, recorded in
/// `commands` as its name after a NUL (which no command line holds), and read back by `requests`.
extension FakeHostConnection {
    static let subsystemMark = "\u{0}subsystem "

    func channel(subsystem name: String) async throws(TransportError) -> any ByteConnection {
        try await channel(command: Self.subsystemMark + name)
    }

    /// Every channel asked for, in order, as the request it was.
    var requests: [ChannelRequest] {
        commands.map { command in
            command.hasPrefix(Self.subsystemMark)
                ? .subsystem(String(command.dropFirst(Self.subsystemMark.count))) : .command(command)
        }
    }
}
