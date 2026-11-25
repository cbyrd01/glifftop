import Testing

@testable import GliffTransport

/// The config's forwards as `ssh -G` prints them (OpenSSH 10.5p1): a host always in brackets,
/// a listen address only when the config gave one, a unix socket as its path.
struct SSHLocalForwardTests {
    @Test(arguments: [
        ("3000 [localhost]:3000", SSHLocalForward(port: 3000, host: "localhost", hostPort: 3000)),
        (
            "[127.0.0.1]:5432 [db]:5432",
            SSHLocalForward(port: 5432, host: "db", hostPort: 5432, bind: "127.0.0.1")
        ),
        ("8080 [::1]:80", SSHLocalForward(port: 8080, host: "::1", hostPort: 80)),
        (
            "[::1]:8081 [fe80::1%en0]:80",
            SSHLocalForward(port: 8081, host: "fe80::1%en0", hostPort: 80, bind: "::1")
        ),
        ("[*]:9002 [h]:9002", SSHLocalForward(port: 9002, host: "h", hostPort: 9002, bind: "*")),
        ("9003 db.example:9003", SSHLocalForward(port: 9003, host: "db.example", hostPort: 9003)),
    ])
    func aLocalForwardIsRead(_ value: String, forward: SSHLocalForward) {
        #expect(SSHLocalForward(resolved: value) == forward)
    }

    @Test(arguments: [
        "/tmp/x.sock [host]:22", "9000 /tmp/remote.sock", "0 [h]:80", "70000 [h]:80", "80 [h]:0",
        "80 []:80", "80", "x [h]:80", "80 [h]:x", "80 [h:80",
    ])
    func aSocketOrUnreadableForwardIsNone(_ value: String) {
        #expect(SSHLocalForward(resolved: value) == nil)
    }

    /// Each `localforward` line that can be applied, in order; every other forward is counted.
    @Test func theConfigsForwardsAreRead() {
        let config = SSHResolvedConfig(
            resolved: """
                hostname omarchy
                dynamicforward 1080
                localforward 3000 [localhost]:3000
                localforward /tmp/x.sock [host]:22
                localforward [127.0.0.1]:5432 [db]:5432
                remoteforward 9001 [localhost]:9001

                """)
        #expect(
            config.localForwards == [
                SSHLocalForward(port: 3000, host: "localhost", hostPort: 3000),
                SSHLocalForward(port: 5432, host: "db", hostPort: 5432, bind: "127.0.0.1"),
            ])
        #expect(config.notAppliedLines.count == 3)
    }

    /// The listen side's address is kept as the config wrote it, for display only.
    @Test(arguments: [
        ("[*]:8080 [::1]:80", "*"), ("*:8080 [::1]:80", "*"), ("[127.0.0.1]:5432 [db]:5432", "127.0.0.1"),
        ("[::1]:8081 [h]:80", "::1"), ("3000 [localhost]:3000", nil),
    ])
    func theBindAddressIsKept(_ value: String, bind: String?) throws {
        #expect(try #require(SSHLocalForward(resolved: value)).bind == bind)
    }

    /// A local port under 1024 is never asked of ssh: its line is listed as not applied.
    @Test func aPortUnder1024IsNotApplied() {
        let config = SSHResolvedConfig(resolved: "localforward 80 [localhost]:80\nlocalforward 1024 [h]:1\n")
        #expect(config.localForwards == [SSHLocalForward(port: 1024, host: "h", hostPort: 1)])
        #expect(config.notAppliedLines == ["localforward 80 [localhost]:80"])
    }

    /// Each line not applied keeps its text as `ssh -G` printed it, in order.
    @Test func notAppliedLinesKeepTheirText() {
        let config = SSHResolvedConfig(
            resolved: """
                dynamicforward 1080
                localforward /tmp/x.sock [host]:22
                remoteforward 9001 [localhost]:9001

                """)
        #expect(
            config.notAppliedLines == [
                "dynamicforward 1080", "localforward /tmp/x.sock [host]:22",
                "remoteforward 9001 [localhost]:9001",
            ])
        #expect(config.notAppliedLines.count == 3)
    }

    /// A destination a `PortForward` can't hold (an IPv6 zone) is listed, not applied.
    @Test func aDestinationWithAZoneIsNotApplied() {
        let config = SSHResolvedConfig(resolved: "localforward 8081 [fe80::1%en0]:80\n")
        #expect(config.localForwards.isEmpty)
        #expect(config.notAppliedLines == ["localforward 8081 [fe80::1%en0]:80"])
    }

    /// Each applied one is also a `ConfiguredForward`, its config IP literal an address.
    @Test func eachAppliedForwardIsConfigured() throws {
        let forward = SSHLocalForward(port: 8080, host: "::1", hostPort: 80, bind: "*")
        let configured = try #require(forward.configured)
        #expect(configured.bind == "*")
        #expect(
            configured.forward
                == PortForward(localPort: 8080, destination: .address(IPLiteral("::1")!), remotePort: 80))
    }

    @Test func noForwardsByDefault() {
        let config = SSHResolvedConfig(resolved: "hostname omarchy\n")
        #expect(config.localForwards.isEmpty && config.notAppliedLines.count == 0)
    }
}
