import Testing

@testable import GliffTransport

struct PortForwardTests {
    @Test func aLocalPortUnder1024IsRefused() {
        #expect(PortForward(localPort: 80, destination: .localhost, remotePort: 80) == nil)
        #expect(PortForward(localPort: 1023, destination: .localhost, remotePort: 80) == nil)
        #expect(PortForward(localPort: 65536, destination: .localhost, remotePort: 80) == nil)
        #expect(PortForward(localPort: 1024, destination: .localhost, remotePort: 80)?.localPort == 1024)
    }

    @Test func aRemotePortOutsideRangeIsRefused() {
        #expect(PortForward(localPort: 8080, destination: .localhost, remotePort: 0) == nil)
        #expect(PortForward(localPort: 8080, destination: .localhost, remotePort: 65536) == nil)
        #expect(PortForward(localPort: 8080, destination: .localhost, remotePort: 1)?.remotePort == 1)
    }

    @Test(arguments: [
        ("127.0.0.1", false, true), ("192.0.2.10", false, false), ("::1", true, true),
        ("2001:db8::1", true, false), ("::ffff:127.0.0.1", true, true),
    ])
    func anIPLiteralParses(_ text: String, isIPv6: Bool, isLoopback: Bool) throws {
        let literal = try #require(IPLiteral(text))
        #expect(literal.text == text)
        #expect(literal.isIPv6 == isIPv6)
        #expect(literal.isLoopback == isLoopback)
    }

    /// The canonical text: an address written another way reads back as inet_ntop writes it.
    @Test func anIPv6LiteralKeepsItsCanonicalText() {
        #expect(IPLiteral("2001:DB8:0:0:0:0:0:1")?.text == "2001:db8::1")
        #expect(IPLiteral("0:0:0:0:0:0:0:1") == IPLiteral("::1"))
    }

    @Test(arguments: ["", "localhost", "1.2.3", "fe80::1%lo0", "[::1]", "1.2.3.4 ", " 1.2.3.4", "256.1.1.1"])
    func aNonLiteralIsRefused(_ text: String) {
        #expect(IPLiteral(text) == nil)
    }

    /// A config's "localhost", in any case, is the same destination the person picks.
    @Test(arguments: ["localhost", "LocalHost"])
    func aConfiguredLocalhostIsLocalhost(_ host: String) {
        #expect(ForwardDestination(configuredHost: host) == .localhost)
    }

    @Test(arguments: ["db", "db_host", "db.internal"])
    func aConfiguredHostIsKept(_ host: String) throws {
        let destination = try #require(ForwardDestination(configuredHost: host))
        #expect(destination.host == host)
    }

    @Test(arguments: ["", "a b", "a\nb", "a\tb", "a\0b", "a\u{85}b"])
    func aConfiguredHostWithSpaceIsRefused(_ host: String) {
        #expect(ForwardDestination(configuredHost: host) == nil)
    }

    /// A unix socket path, or `-L`'s brackets, would change what the spec says.
    @Test(arguments: ["/tmp/x.sock", "a]b", "[db", "db]", "x:9", "fe80::1%en0", "db%1"])
    func aConfiguredHostWithSpecSyntaxIsRefused(_ host: String) {
        #expect(ForwardDestination(configuredHost: host) == nil)
    }

    /// A config's IP literal is an address, equal to the same forward made by hand.
    @Test(arguments: ["::1", "127.0.0.1", "2001:db8::1"])
    func aConfiguredLiteralIsAnAddress(_ host: String) throws {
        let literal = try #require(IPLiteral(host))
        #expect(ForwardDestination(configuredHost: host) == .address(literal))
    }

    @Test func eachDestinationNamesItsHost() throws {
        #expect(ForwardDestination.localhost.host == "localhost")
        let address = try #require(IPLiteral("2001:db8::1"))
        #expect(ForwardDestination.address(address).host == "2001:db8::1")
    }

    @Test func theFakeRecordsForwardsInOrder() async throws {
        let connection = FakeHostConnection()
        let web = try #require(PortForward(localPort: 5173, destination: .localhost, remotePort: 5173))
        let api = try #require(PortForward(localPort: 8080, destination: .localhost, remotePort: 8080))
        connection.answer(web, on: .ipv6, with: .localPortInUse)
        try await connection.forward(web, on: .ipv4)
        await #expect(throws: ForwardError.localPortInUse) { try await connection.forward(web, on: .ipv6) }
        try await connection.cancel(api, on: .ipv4)
        #expect(
            connection.forwardCalls == [
                .forward(web, .ipv4), .forward(web, .ipv6), .cancel(api, .ipv4),
            ])
    }

    @Test func theFakesConfiguredForwardsAreSettable() async throws {
        let connection = FakeHostConnection()
        let host: any HostConnection = connection
        #expect(await host.configuredForwards == .none)
        let forward = try #require(PortForward(localPort: 5432, destination: .localhost, remotePort: 5432))
        let configured = ConfiguredForwards(
            local: [ConfiguredForward(forward: forward, bind: "*")], notApplied: ["remoteforward 9000"])
        connection.configuredForwards = configured
        #expect(await host.configuredForwards == configured)
    }
}
