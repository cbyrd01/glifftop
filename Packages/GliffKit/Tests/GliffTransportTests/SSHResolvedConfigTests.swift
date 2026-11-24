import Testing

@testable import GliffTransport

/// `ssh -G` prints booleans as `yes`/`no` or `true`/`false`, and StrictHostKeyChecking as
/// `true`, `false`, `ask` or `accept-new` (OpenSSH 10.5p1).
struct SSHResolvedConfigTests {
    @Test func theFieldsAreRead() {
        let config = SSHResolvedConfig(
            resolved: "hostname 192.0.2.5\nport 2222\nbatchmode no\nstricthostkeychecking true\n"
                + "updatehostkeys ask\nhostkeyalias box\nconnecttimeout none\nproxyjump bastion\n")
        #expect(!config.batchMode)
        #expect(config.strictHostKeyChecking == "true")
        #expect(config.updateHostKeys == "ask")
        #expect(config.hasProxy && config.connectTimeoutUnset)
        #expect(config.hostName == "192.0.2.5" && config.port == 2222 && config.hostKeyAlias == "box")
    }

    @Test func unreadableTextGivesSSHsDefaults() {
        let config = SSHResolvedConfig(resolved: "Bad configuration option: x\n")
        #expect(!config.batchMode && config.strictHostKeyChecking == "ask")
        #expect(config.updateHostKeys == "true")
        #expect(!config.hasProxy && !config.connectTimeoutUnset)
        #expect(config.hostName == nil && config.port == 22 && config.hostKeyAlias == nil)
    }

    @Test(arguments: ["proxyjump none", "proxycommand none", ""])
    func noProxy(_ line: String) {
        #expect(!SSHResolvedConfig(resolved: line + "\n").hasProxy)
    }

    /// The names ssh writes for the destination in its questions.
    @Test func theDestinationsNames() {
        #expect(
            SSHResolvedConfig(resolved: "hostname 192.0.2.5\nhostkeyalias box\n").names == [
                "192.0.2.5", "box",
            ])
        #expect(SSHResolvedConfig(resolved: "hostname omarchy\n").names == ["omarchy"])
    }

    /// The name of the destination's known_hosts entry: HostKeyAlias as it is, else HostName,
    /// `[name]:port` off port 22.
    @Test func theKnownHostsName() {
        #expect(SSHResolvedConfig(resolved: "hostname omarchy\nport 22\n").knownHostsName == "omarchy")
        #expect(
            SSHResolvedConfig(resolved: "hostname 192.0.2.5\nport 2222\n").knownHostsName
                == "[192.0.2.5]:2222")
        #expect(
            SSHResolvedConfig(resolved: "hostname 192.0.2.5\nport 2222\nhostkeyalias box\n").knownHostsName
                == "box")
        #expect(SSHResolvedConfig(resolved: "").knownHostsName == nil)
    }

    @Test(arguments: ["true", "yes"])
    func configStrictYesStaysYes(_ value: String) {
        #expect(
            MasterAsking(config: SSHResolvedConfig(resolved: "stricthostkeychecking \(value)\n"))?
                .strictHostKeyChecking == "yes")
    }

    @Test(arguments: ["accept-new", "false", "no", "ask"])
    func anyOtherStrictBecomesAsk(_ value: String) {
        #expect(
            MasterAsking(config: SSHResolvedConfig(resolved: "stricthostkeychecking \(value)\n"))?
                .strictHostKeyChecking == "ask")
    }

    @Test(arguments: ["yes", "true"])
    func configBatchModeMeansNoAsking(_ value: String) {
        #expect(MasterAsking(config: SSHResolvedConfig(resolved: "batchmode \(value)\n")) == nil)
    }

    @Test func configUpdateHostKeysAskIsTurnedOff() {
        #expect(
            MasterAsking(config: SSHResolvedConfig(resolved: "updatehostkeys ask\n"))?.updateHostKeysOff
                == true)
        #expect(
            MasterAsking(config: SSHResolvedConfig(resolved: "updatehostkeys true\n"))?.updateHostKeysOff
                == false)
    }

    /// `-G` resolves the config and exits, without connecting. ssh keeps an option's first
    /// value, so the probe passes none of the app's own: it reads the person's config.
    @Test func theProbeAsksSSHWithoutConnecting() throws {
        let target = try SSHTarget("user@omarchy")
        #expect(
            SSHResolvedConfig.probeArguments(sshArguments: ["-p", "2222"], target: target) == [
                "-G", "-T", "-p", "2222", "--", "user@omarchy",
            ])
    }

    #if os(macOS)
        @Test func theProbeReadsTheResolvedConfig() async {
            let config = await SSHResolvedConfig.probe(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'hostname omarchy\\nconnecttimeout none\\n'"],
                timeout: .seconds(10))
            #expect(config?.hostName == "omarchy" && config?.connectTimeoutUnset == true)
        }

        /// A config whose `Match exec` hangs, or an ssh that fails: no config.
        @Test(arguments: [["-c", "sleep 10"], ["-c", "echo 'connecttimeout none'; exit 255"]])
        func aProbeThatHangsOrFailsGivesNothing(_ arguments: [String]) async {
            let config = await SSHResolvedConfig.probe(
                executable: "/bin/sh", arguments: arguments, timeout: .milliseconds(300))
            #expect(config == nil)
        }
    #endif
}
