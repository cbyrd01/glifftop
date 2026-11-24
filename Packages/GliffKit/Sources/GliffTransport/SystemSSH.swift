#if os(macOS)
    public import Foundation

    /// The app's opener for `HostConnections`. Every opener shares one numbering of sockets in
    /// one directory, prepared at launch (`prepare()`), else on the first open: the masters of
    /// Glifftops no longer running are ended then.
    public enum SystemSSH {
        /// Prepares the sockets' directory now, ending stale masters: at the app's launch.
        public static func prepare() async { await SystemSSHSockets.shared.prepare() }

        /// Opens with `helper`, the app's askpass helper. It passes no `SignInAsker` yet, so its
        /// masters run in batch mode.
        public static func opener(helper: URL? = nil) -> HostConnections.Open {
            { target throws(TransportError) in
                try await SystemSSHConnection.open(
                    target: target, socket: SystemSSHSockets.shared.next(), helper: helper)
            }
        }
    }

    /// The sockets' directory, prepared once it works, and the next socket's number.
    actor SystemSSHSockets {
        static let shared = SystemSSHSockets(prepare: standard)

        private let makeDirectory: @Sendable () async -> ControlSocketDirectory?
        private var directory: Task<ControlSocketDirectory?, Never>?
        private var number: UInt32 = 0

        init(prepare: @escaping @Sendable () async -> ControlSocketDirectory?) { makeDirectory = prepare }

        /// The directory, prepared once it works: a failure is tried again next time.
        func prepare() async { _ = await prepared() }

        func next() async throws(TransportError) -> String {
            guard let directory = await prepared() else {
                throw .launchFailed("There's no private folder for ssh's connections.")
            }
            number &+= 1
            return directory.socketPath(number: number)
        }

        private func prepared() async -> ControlSocketDirectory? {
            let preparing = directory ?? Task { [makeDirectory] in await makeDirectory() }
            directory = preparing
            let prepared = await preparing.value
            if prepared == nil, directory == preparing { directory = nil }
            return prepared
        }

        private static func standard() async -> ControlSocketDirectory? {
            guard let directory = try? ControlSocketDirectory.standard() else { return nil }
            // `-O exit` needs a destination, but `-S` alone names the master: `.invalid` is a
            // name that can never be a host (RFC 6761).
            guard let placeholder = try? SSHTarget("glifftop.invalid") else { return directory }
            await directory.removeStale(ending: { socket in
                _ = await ProcessOutput.read(
                    executable: URL(filePath: SSHCommand.executable),
                    arguments: SSHMasterCommand(target: placeholder, socket: socket).exit,
                    maxBytes: 4096, timeout: .seconds(5))
            })
            return directory
        }
    }
#endif
