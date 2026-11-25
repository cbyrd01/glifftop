/// ssh's connect timeout, `-o ConnectTimeout=10`: a host that drops packets fails in 10 s
/// rather than macOS's 75 s, so a reconnect's try never stalls for long. Added only when the
/// person's ssh_config, as `ssh -G` resolves it (`SSHResolvedConfig`), sets no timeout of its
/// own and no proxy: through ProxyJump or ProxyCommand the wait for the host's greeting
/// includes signing in to the jump host, a 1Password approval too. A probe that fails means no
/// timeout.
enum SSHConnectTimeout {
    static let options = ["-o", "ConnectTimeout=10"]

    static func isWanted(config: SSHResolvedConfig) -> Bool {
        !config.hasProxy && config.connectTimeoutUnset
    }

    #if os(macOS)
        /// Probes the system ssh about `target`, with the options a command built from
        /// `sshArguments` passes.
        static func isWanted(sshArguments: [String], target: SSHTarget) async -> Bool {
            await SSHResolvedConfig.probe(sshArguments: sshArguments, target: target).map(isWanted) ?? false
        }
    #endif
}
