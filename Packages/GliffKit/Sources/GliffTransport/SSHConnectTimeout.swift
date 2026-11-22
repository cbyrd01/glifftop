/// ssh's connect timeout, `-o ConnectTimeout=10`: a host that drops packets fails in 10 s
/// rather than macOS's 75 s, so a reconnect's try never stalls for long. Added only when the
/// person's ssh_config, as `ssh -G` resolves it, sets no timeout of its own and no proxy:
/// through ProxyJump or ProxyCommand the wait for the host's greeting includes signing in to
/// the jump host, a 1Password approval too. `ssh -G` runs the config's `Match exec` commands
/// as a connect does, so each runs twice; a probe still running after 5 s is ended (ssh, not a
/// command it started) and the connect goes ahead without the timeout.
enum SSHConnectTimeout {
    static let options = ["-o", "ConnectTimeout=10"]

    /// Whether `ssh -G`'s output sets `connecttimeout none` and no proxy. Anything else,
    /// unreadable text included, keeps ssh's own behaviour.
    static func isWanted(resolvedConfig: String) -> Bool {
        var unset = false
        for line in resolvedConfig.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ", maxSplits: 1)
            guard words.count == 2 else { continue }
            switch words[0].lowercased() {
            case "connecttimeout": unset = words[1] == "none"
            case "proxyjump", "proxycommand": if words[1] != "none" { return false }
            default: continue
            }
        }
        return unset
    }

    /// `ssh -G`: the config resolved for `target` with `options`, printed without connecting.
    static func probeArguments(options: [String], target: SSHTarget) -> [String] {
        ["-G"] + options + ["--", target.value]
    }
}

#if os(macOS)
    import Foundation

    extension SSHConnectTimeout {
        /// Asks the system ssh about `target`, with the options a command built from
        /// `sshArguments` passes.
        static func isWanted(sshArguments: [String], target: SSHTarget) async -> Bool {
            await isWanted(
                executable: SSHCommand.executable,
                arguments: probeArguments(options: SSHCommand.options(sshArguments), target: target),
                timeout: .seconds(5))
        }

        /// Runs the probe: false when it fails or hasn't answered within `timeout` (a
        /// `Match exec` that hangs).
        static func isWanted(executable: String, arguments: [String], timeout: Duration) async -> Bool {
            let output = await ProcessOutput.read(
                executable: URL(filePath: executable), arguments: arguments, maxBytes: 64 * 1024,
                timeout: timeout)
            guard case .success(let bytes) = output else { return false }
            return isWanted(resolvedConfig: String(decoding: bytes, as: UTF8.self))
        }
    }
#endif
