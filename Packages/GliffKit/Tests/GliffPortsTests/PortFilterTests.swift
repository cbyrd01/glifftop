import GliffTransport
import Testing

@testable import GliffPorts

/// Which of the person's listening sockets are offered, and where a forward of each goes.
@Suite struct PortFilterTests {
    static func socket(_ address: String, _ port: Int, name: String? = "node", uid: Int = 1000)
        -> ListeningSocket
    {
        ListeningSocket(address: IPLiteral(address)!, port: port, uid: uid, name: name)
    }

    static func frame(_ sockets: [ListeningSocket]) -> PortFrame {
        PortFrame(uid: 1000, ephemeral: 32768...60999, sockets: sockets)
    }

    static func split(_ sockets: [ListeningSocket], forwarded: Set<Int> = [])
        -> (available: [RemotePort], other: [RemotePort])
    {
        PortFilter.split(frame(sockets), forwarded: forwarded)
    }

    /// The name shown is that of the socket the forward goes to.
    @Test func theNameIsTheDestinationSockets() {
        let split = Self.split([
            Self.socket("192.0.2.10", 5173, name: "vite"), Self.socket("127.0.0.1", 5173),
        ])
        #expect(
            split.available == [
                RemotePort(port: 5173, destination: .address(IPLiteral("127.0.0.1")!), name: "node")
            ])
    }

    @Test func loopbackAndWildcardOutsideEphemeralAreAvailable() {
        let split = Self.split([
            Self.socket("127.0.0.1", 5173), Self.socket("::1", 6006), Self.socket("0.0.0.0", 8080),
            Self.socket("::", 3000), Self.socket("::ffff:127.0.0.1", 4000),
        ])
        #expect(split.available.map(\.port) == [3000, 4000, 5173, 6006, 8080])
        #expect(split.other.isEmpty)
    }

    @Test func ephemeralAndLANGoToOther() {
        let split = Self.split([
            Self.socket("127.0.0.1", 40000), Self.socket("192.0.2.10", 5173),
            Self.socket("2001:db8::1", 6006),
        ])
        #expect(split.available.isEmpty)
        #expect(split.other.map(\.port) == [5173, 6006, 40000])
    }

    @Test(arguments: ["gliff-server", "gliff", "sshd", "sshd-session"])
    func gliffAndSSHDAreNeverOffered(_ name: String) {
        let split = Self.split([
            Self.socket("127.0.0.1", 7000, name: name), Self.socket("127.0.0.1", 40001, name: name),
        ])
        #expect(split.available.isEmpty)
        #expect(split.other.isEmpty)
    }

    @Test func anotherUsersSocketIsLeftOut() {
        let split = Self.split([Self.socket("127.0.0.1", 5173, uid: 0)])
        #expect(split.available.isEmpty)
        #expect(split.other.isEmpty)
    }

    @Test func aPortOnBothWildcardsIsOneEntry() {
        let split = Self.split([Self.socket("0.0.0.0", 8080), Self.socket("::", 8080, name: nil)])
        #expect(split.available == [RemotePort(port: 8080, destination: .localhost, name: "node")])
    }

    @Test func aPortOnLoopbackAndLANIsAvailable() {
        let split = Self.split([Self.socket("192.0.2.10", 5173), Self.socket("127.0.0.1", 5173)])
        #expect(split.available.map(\.port) == [5173])
        #expect(split.other.isEmpty)
    }

    @Test func forwardedPortsAreLeftOut() {
        let split = Self.split(
            [Self.socket("127.0.0.1", 5173), Self.socket("192.0.2.10", 6006)], forwarded: [5173, 6006])
        #expect(split.available.isEmpty)
        #expect(split.other.isEmpty)
    }

    @Test(arguments: [
        ("0.0.0.0", ForwardDestination.localhost), ("::", .localhost),
        ("127.0.0.1", .address(IPLiteral("127.0.0.1")!)), ("::1", .address(IPLiteral("::1")!)),
        ("::ffff:127.0.0.1", .address(IPLiteral("127.0.0.1")!)),
        ("192.0.2.10", .address(IPLiteral("192.0.2.10")!)),
        ("::ffff:192.0.2.10", .address(IPLiteral("192.0.2.10")!)),
    ])
    func theDestinationComesFromTheAddress(_ address: String, _ destination: ForwardDestination) {
        let split = Self.split([Self.socket(address, 5173)])
        #expect((split.available + split.other).map(\.destination) == [destination])
    }
}
