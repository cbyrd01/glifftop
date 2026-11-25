import Testing

@testable import GliffTransport

/// The config's forwards as `ssh -G` prints them (OpenSSH 10.5p1): a host always in brackets,
/// a listen address only when the config gave one, a unix socket as its path.
struct SSHLocalForwardTests {
    @Test(arguments: [
        ("3000 [localhost]:3000", SSHLocalForward(port: 3000, host: "localhost", hostPort: 3000)),
        ("[127.0.0.1]:5432 [db]:5432", SSHLocalForward(port: 5432, host: "db", hostPort: 5432)),
        ("8080 [::1]:80", SSHLocalForward(port: 8080, host: "::1", hostPort: 80)),
        ("[::1]:8081 [fe80::1%en0]:80", SSHLocalForward(port: 8081, host: "fe80::1%en0", hostPort: 80)),
        ("[*]:9002 [h]:9002", SSHLocalForward(port: 9002, host: "h", hostPort: 9002)),
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
                SSHLocalForward(port: 5432, host: "db", hostPort: 5432),
            ])
        #expect(config.forwardsNotApplied == 3)
    }

    @Test func noForwardsByDefault() {
        let config = SSHResolvedConfig(resolved: "hostname omarchy\n")
        #expect(config.localForwards.isEmpty && config.forwardsNotApplied == 0)
    }
}
