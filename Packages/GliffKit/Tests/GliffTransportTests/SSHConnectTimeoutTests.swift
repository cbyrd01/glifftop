import Testing

@testable import GliffTransport

/// ssh's `ConnectTimeout=10` only where the person's ssh_config, as `ssh -G` resolves it,
/// sets no timeout of its own and no proxy.
@Suite struct SSHConnectTimeoutTests {
    private func wanted(_ text: String) -> Bool {
        SSHConnectTimeout.isWanted(config: SSHResolvedConfig(resolved: text))
    }

    @Test func wantedWhenTheConfigSetsNeitherATimeoutNorAProxy() {
        #expect(wanted("user alice\nhostname omarchy\nport 22\nconnecttimeout none\nproxycommand none\n"))
    }

    @Test func thePersonsOwnTimeoutWins() {
        #expect(!wanted("hostname omarchy\nconnecttimeout 45\n"))
    }

    /// Through a jump host, the wait for the host's greeting includes signing in to the jump
    /// host, a 1Password approval too.
    @Test(arguments: ["proxyjump bastion", "proxycommand nc %h %p"])
    func notThroughAProxy(_ line: String) {
        #expect(!wanted("connecttimeout none\n\(line)\n"))
    }

    @Test(arguments: ["", "Bad configuration option: x\n"])
    func notWhenTheConfigCantBeRead(_ text: String) {
        #expect(!wanted(text))
    }
}
