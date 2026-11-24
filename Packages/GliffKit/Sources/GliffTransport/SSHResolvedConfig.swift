/// The person's ssh_config for a destination as `ssh -G` resolves it, read once per open. Text
/// it can't read gives ssh's own defaults. Its output, stderr included, is never logged.
///
/// `ssh -G` runs the config's `Match exec` commands as a connect does, so each runs twice; a
/// probe still running after 5 s is ended (ssh, not a command it started) and the open goes
/// ahead without it.
public struct SSHResolvedConfig: Equatable, Sendable {
    public var batchMode = false
    /// `true`, `false`, `ask` or `accept-new`, as `ssh -G` prints it.
    public var strictHostKeyChecking = "ask"
    /// `true`, `false` or `ask`, as `ssh -G` prints it.
    public var updateHostKeys = "true"
    public var hasProxy = false
    /// `connecttimeout none`: the config sets no timeout of its own.
    public var connectTimeoutUnset = false
    public var hostName: String?
    public var hostKeyAlias: String?
    public var port = 22

    public init(resolved text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ", maxSplits: 1)
            guard words.count == 2 else { continue }
            let value = String(words[1])
            switch words[0].lowercased() {
            case "batchmode": batchMode = Self.isOn(value)
            case "stricthostkeychecking": strictHostKeyChecking = value
            case "updatehostkeys": updateHostKeys = value
            case "proxyjump", "proxycommand": hasProxy = hasProxy || value != "none"
            case "connecttimeout": connectTimeoutUnset = value == "none"
            case "hostname": hostName = value
            case "hostkeyalias": hostKeyAlias = value == "none" ? nil : value
            case "port": port = Int(value) ?? port
            default: continue
            }
        }
    }

    /// The names ssh writes for the destination in its questions: HostName and HostKeyAlias.
    public var names: Set<String> { Set([hostName, hostKeyAlias].compactMap(\.self)) }

    /// The name of the destination's known_hosts entry, as ssh looks it up: HostKeyAlias as it
    /// is, else HostName, as `[name]:port` off port 22.
    public var knownHostsName: String? {
        if let hostKeyAlias { return hostKeyAlias }
        return hostName.map { port == 22 ? $0 : "[\($0)]:\(port)" }
    }

    static func isOn(_ value: String) -> Bool { value == "yes" || value == "true" }

    /// `ssh -G`: the config resolved for `target` with the person's `sshArguments`, printed
    /// without connecting. ssh keeps an option's first value, so none of the app's own options
    /// are passed: they would hide the person's config.
    static func probeArguments(sshArguments: [String], target: SSHTarget) -> [String] {
        ["-G", "-T"] + sshArguments + ["--", target.value]
    }
}

/// How a master that may ask a question runs, from the person's config; nil when the config
/// sets `BatchMode yes`, which asks nothing.
///
/// - `strictHostKeyChecking`: `yes` when the config says so, else `ask`. `accept-new` and `no`
///   would trust a key nobody saw, so they ask instead.
/// - `updateHostKeysOff`: a config's `UpdateHostKeys ask` is turned off, since its question
///   comes after sign-in, when no window is waiting.
public struct MasterAsking: Equatable, Sendable {
    public var strictHostKeyChecking: String
    public var updateHostKeysOff: Bool

    public init?(config: SSHResolvedConfig) {
        guard !config.batchMode else { return nil }
        strictHostKeyChecking = SSHResolvedConfig.isOn(config.strictHostKeyChecking) ? "yes" : "ask"
        updateHostKeysOff = config.updateHostKeys == "ask"
    }
}

#if os(macOS)
    import Foundation

    extension SSHResolvedConfig {
        /// Asks the system ssh about `target` with the person's `sshArguments`; nil when the
        /// probe fails or takes over 5 s.
        static func probe(sshArguments: [String], target: SSHTarget) async -> SSHResolvedConfig? {
            await probe(
                executable: SSHCommand.executable,
                arguments: probeArguments(sshArguments: sshArguments, target: target), timeout: .seconds(5))
        }

        static func probe(executable: String, arguments: [String], timeout: Duration) async
            -> SSHResolvedConfig?
        {
            let output = await ProcessOutput.read(
                executable: URL(filePath: executable), arguments: arguments, maxBytes: 64 * 1024,
                timeout: timeout, logsStderr: false)
            guard case .success(let bytes) = output else { return nil }
            return SSHResolvedConfig(resolved: String(decoding: bytes, as: UTF8.self))
        }
    }
#endif
