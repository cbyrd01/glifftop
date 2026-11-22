import Testing

@testable import GliffTransport

/// ssh's `ConnectTimeout=10` only where the person's ssh_config, as `ssh -G` resolves it,
/// sets no timeout of its own and no proxy.
@Suite struct SSHConnectTimeoutTests {
    @Test func wantedWhenTheConfigSetsNeitherATimeoutNorAProxy() {
        #expect(
            SSHConnectTimeout.isWanted(
                resolvedConfig:
                    "user alice\nhostname omarchy\nport 22\nconnecttimeout none\nproxycommand none\n"))
    }

    @Test func thePersonsOwnTimeoutWins() {
        #expect(!SSHConnectTimeout.isWanted(resolvedConfig: "hostname omarchy\nconnecttimeout 45\n"))
    }

    /// Through a jump host, the wait for the host's greeting includes signing in to the jump
    /// host, a 1Password approval too.
    @Test(arguments: ["proxyjump bastion", "proxycommand nc %h %p"])
    func notThroughAProxy(_ line: String) {
        #expect(!SSHConnectTimeout.isWanted(resolvedConfig: "connecttimeout none\n\(line)\n"))
    }

    @Test(arguments: ["", "Bad configuration option: x\n"])
    func notWhenTheConfigCantBeRead(_ text: String) {
        #expect(!SSHConnectTimeout.isWanted(resolvedConfig: text))
    }

    /// `-G` resolves the config and exits, without connecting.
    @Test func theProbeAsksSSHWithoutConnecting() throws {
        let target = try SSHTarget("user@omarchy")
        #expect(
            SSHConnectTimeout.probeArguments(options: ["-T", "-p", "2222"], target: target) == [
                "-G", "-T", "-p", "2222", "--", "user@omarchy",
            ])
    }

    #if os(macOS)
        @Test func theProbeReadsTheResolvedConfig() async {
            let wanted = await SSHConnectTimeout.isWanted(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'hostname omarchy\\nconnecttimeout none\\n'"],
                timeout: .seconds(10))
            #expect(wanted)
        }

        /// A config whose `Match exec` hangs, or an ssh that fails: no timeout, ssh's own behaviour.
        @Test(arguments: [["-c", "sleep 10"], ["-c", "echo 'connecttimeout none'; exit 255"]])
        func aProbeThatHangsOrFailsMeansNone(_ arguments: [String]) async {
            let wanted = await SSHConnectTimeout.isWanted(
                executable: "/bin/sh", arguments: arguments, timeout: .milliseconds(300))
            #expect(!wanted)
        }
    #endif
}
