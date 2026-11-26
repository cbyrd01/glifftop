public import GliffTransport

/// Keeps one `HostFiles` per host, by the host as typed, for the app's life.
public actor FilesRegistry {
    private let make: @Sendable (SSHTarget) -> HostFiles
    private var hosts: [String: HostFiles] = [:]

    /// Each host's channels on `connections`, sharing one ledger.
    public init(
        connections: HostConnections, ledger: TemporaryLedger,
        activity: any TransferActivity = ProcessActivity()
    ) {
        self.init { target in
            HostFiles(
                host: target.value, channels: FilesChannels(connections: connections, target: target),
                ledger: ledger, activity: activity)
        }
    }

    init(make: @escaping @Sendable (SSHTarget) -> HostFiles) { self.make = make }

    public func files(for target: SSHTarget) -> HostFiles {
        if let files = hosts[target.value] { return files }
        let files = make(target)
        hosts[target.value] = files
        return files
    }

    /// The hosts with a batch queued or running.
    public func hostsWithWork() async -> [String] {
        var busy: [String] = []
        for (host, files) in hosts where await files.hasWork { busy.append(host) }
        return busy
    }
}
