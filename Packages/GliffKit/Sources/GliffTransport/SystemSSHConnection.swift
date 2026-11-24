#if os(macOS)
    import Foundation
    import Synchronization
    import os

    /// A shared connection through the system ssh: a ControlMaster this app starts and ends,
    /// on a socket in `ControlSocketDirectory`.
    ///
    /// - `open` starts the master and returns once its socket answers `-O check`; a master that
    ///   exits first throws why, in `SSHErrorClassifier`'s words. It waits up to 60 s, room for
    ///   a 1Password approval.
    /// - Each channel is one ssh through the socket (`SSHMasterCommand.channel`), its stderr read
    ///   by `SSHErrorClassifier.classifyChannel`.
    /// - The master's exit ends the connection, and its socket is removed: `ended()` says why,
    ///   nil only after `close()`. A master that ends itself, even cleanly, is a lost connection.
    /// - A sign-in still unfinished after 60 s fails as `.signInTimedOut`, which is not retried:
    ///   a retry would only ask for the approval again.
    public final class SystemSSHConnection: HostConnection {
        private let command: SSHMasterCommand
        private let executable: URL
        private let master: ProcessConnection

        private struct State {
            var end: ConnectFailure??
            var waiters: [CheckedContinuation<ConnectFailure?, Never>] = []
            /// invalidate() ended it: the link is dead, whatever the master said.
            var invalidated = false
            /// close() ended it: whatever the master said, nothing was lost.
            var closing = false
        }
        private let state = Mutex(State())
        private static let log = Logger(subsystem: "me.cbyrd.Glifftop", category: "SystemSSHConnection")

        private init(command: SSHMasterCommand, executable: URL, master: ProcessConnection) {
            (self.command, self.executable, self.master) = (command, executable, master)
        }

        /// Opens a master for `target` on `socket`, with a connect timeout where
        /// `SSHConnectTimeout` finds one wanted.
        public static func open(target: SSHTarget, socket: String) async throws(TransportError)
            -> SystemSSHConnection
        {
            let config = await SSHResolvedConfig.probe(sshArguments: [], target: target)
            let timeout = config.map(SSHConnectTimeout.isWanted) ?? false
            let command = SSHMasterCommand(target: target, socket: socket, connectTimeout: timeout)
            return try await open(command: command, executable: URL(filePath: SSHCommand.executable))
        }

        static func open(
            command: SSHMasterCommand, executable: URL, poll: Duration = .milliseconds(100),
            limit: Duration = .seconds(60)
        ) async throws(TransportError) -> SystemSSHConnection {
            if Task.isCancelled { throw .cancelled }
            let master = try ProcessConnection.launch(
                executable: executable, arguments: command.master, classify: SSHErrorClassifier.classify)
            let connection = SystemSSHConnection(command: command, executable: executable, master: master)
            Task { await connection.watch() }
            do throws(TransportError) {
                try await connection.waitUntilReady(poll: poll, limit: limit)
            } catch {
                await connection.close()
                throw error
            }
            log.info("master ready")
            return connection
        }

        public func channel(command line: String) async throws(TransportError) -> any ByteConnection {
            if hasEnded { throw .exited(status: 255, failure: .sharedConnectionLost) }
            return try ProcessConnection.launch(
                executable: executable, arguments: command.channel(line),
                classify: SSHErrorClassifier.classifyChannel)
        }

        public func ended() async -> ConnectFailure? {
            await withCheckedContinuation { continuation in
                let end = state.withLock { state -> ConnectFailure?? in
                    if state.end == nil { state.waiters.append(continuation) }
                    return state.end
                }
                if let end { continuation.resume(returning: end) }
            }
        }

        public func invalidate() async {
            state.withLock { $0.invalidated = true }
            master.terminate()
            await finish()
        }

        /// `-O exit`, so the master ends its channels itself; if that can't run (a cancelled
        /// task, a master not yet listening) the master is ended with SIGTERM.
        public func close() async {
            let running = state.withLock { state in
                state.closing = true
                return state.end == nil
            }
            if running {
                let exit = await ProcessOutput.read(
                    executable: executable, arguments: command.exit, maxBytes: 4096, timeout: .seconds(5))
                if case .failure = exit { master.terminate() }
            }
            await finish()
        }

        private var hasEnded: Bool { state.withLock { $0.end != nil } }

        /// Reaps the master and removes its socket, should it be left.
        private func finish() async {
            await master.close()
            try? FileManager.default.removeItem(atPath: command.socket)
            ended(with: nil)
        }

        /// Waits for the master's exit, removes its socket and records why it ended.
        private func watch() async {
            var failure = ConnectFailure.sharedConnectionLost
            do {
                for try await _ in master.incoming {}
            } catch TransportError.exited(_, let why) {
                failure = why
            } catch {}
            try? FileManager.default.removeItem(atPath: command.socket)
            ended(with: failure)
        }

        /// Records the end once: `failure` is the master's own, which `invalidate()` and
        /// `close()` override.
        private func ended(with failure: ConnectFailure?) {
            typealias Waiters = [CheckedContinuation<ConnectFailure?, Never>]
            let outcome = state.withLock { state -> (ConnectFailure?, Waiters)? in
                guard state.end == nil else { return nil }
                let end = state.invalidated ? .unreachable : state.closing ? nil : failure
                if !state.invalidated, end != nil { Self.log.info("master ended by itself") }
                state.end = .some(end)
                defer { state.waiters = [] }
                return (end, state.waiters)
            }
            guard let (end, waiters) = outcome else { return }
            for waiter in waiters { waiter.resume(returning: end) }
        }

        /// Until the socket exists (a cheap look, every `poll`), then one `-O check`; the master's
        /// exit, a cancel or `limit` (the master is then ended) first ends the wait.
        private func waitUntilReady(poll: Duration, limit: Duration) async throws(TransportError) {
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                if Task.isCancelled { throw .cancelled }
                if hasEnded {
                    throw .exited(
                        status: master.exitStatus ?? 255,
                        failure: state.withLock { $0.end ?? nil } ?? .other("ssh ended"))
                }
                if FileManager.default.fileExists(atPath: command.socket) {
                    let check = await ProcessOutput.read(
                        executable: executable, arguments: command.check, maxBytes: 4096,
                        timeout: .seconds(5))
                    if case .success = check { return }
                }
                try? await Task.sleep(for: poll)
            }
            master.terminate()
            throw .exited(status: 255, failure: .signInTimedOut)
        }
    }

    /// The app's opener for `HostConnections`. Every opener shares one numbering of sockets in
    /// one directory, prepared at launch (`prepare()`), else on the first open: the masters of
    /// Glifftops no longer running are ended then.
    public enum SystemSSH {
        /// Prepares the sockets' directory now, ending stale masters: at the app's launch.
        public static func prepare() async { await SystemSSHSockets.shared.prepare() }

        public static func opener() -> HostConnections.Open {
            { target throws(TransportError) in
                try await SystemSSHConnection.open(target: target, socket: SystemSSHSockets.shared.next())
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
