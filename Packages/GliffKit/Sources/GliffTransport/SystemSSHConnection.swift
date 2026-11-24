#if os(macOS)
    public import Foundation
    import GliffAskpass
    import Synchronization
    import os

    /// A shared connection through the system ssh: a ControlMaster this app starts and ends,
    /// on a socket in `ControlSocketDirectory`.
    ///
    /// - `open` starts the master and returns once its socket answers `-O check`; a master that
    ///   exits first throws why, in `SSHErrorClassifier`'s words. It waits up to 60 s, room for
    ///   a 1Password approval, not counting time a sign-in question is open, and 5 min in all.
    /// - With someone to ask, the helper, and a config that allows it (`MasterAsking`), the
    ///   master asks its sign-in questions through an `AskpassBridge`, revoked once the master
    ///   is ready or has failed. Its outcome names a failure: Deny, Cancel, too many questions.
    /// - Each channel is one ssh through the socket (`SSHMasterCommand.channel`), its stderr read
    ///   by `SSHErrorClassifier.classifyChannel`.
    /// - The master's exit ends the connection, and its socket is removed: `ended()` says why,
    ///   nil only after `close()`. A master that ends itself, even cleanly, is a lost connection.
    /// - A sign-in still unfinished after its limits fails as `.signInTimedOut`, which is not retried:
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

        /// Opens a master for `target` on `socket`, read through one `ssh -G`: a connect timeout
        /// where `SSHConnectTimeout` finds one wanted, and `questions` asked through `helper`.
        public static func open(
            target: SSHTarget, socket: String, questions: (any SignInAsker)? = nil, helper: URL? = nil
        ) async throws(TransportError) -> SystemSSHConnection {
            let config = await SSHResolvedConfig.probe(sshArguments: [], target: target)
            return try await open(
                target: target, socket: socket, config: config, questions: questions, helper: helper,
                executable: URL(filePath: SSHCommand.executable))
        }

        /// What a master that asks needs: who answers, the helper, and the ssh it must run under.
        struct SignIn {
            let questions: any SignInAsker
            let helper: URL
            let ssh: String
            let names: Set<String>
        }

        static func open(
            target: SSHTarget, socket: String, config: SSHResolvedConfig?, questions: (any SignInAsker)?,
            helper: URL?, executable: URL, ssh: String = SSHCommand.executable,
            limit: Duration = .seconds(60),
            ceiling: Duration = .seconds(300)
        ) async throws(TransportError) -> SystemSSHConnection {
            let asking = config.flatMap(MasterAsking.init(config:))
            let signIn: SignIn? =
                if let questions, let helper, let config, asking != nil {
                    SignIn(questions: questions, helper: helper, ssh: ssh, names: config.names)
                } else { nil }
            let command = SSHMasterCommand(
                target: target, socket: socket,
                connectTimeout: config.map(SSHConnectTimeout.isWanted) ?? false,
                asking: signIn == nil ? nil : asking)
            return try await open(
                command: command, executable: executable, signIn: signIn,
                knownHostsName: config?.hasProxy == false ? config?.knownHostsName : nil,
                limit: limit, ceiling: ceiling)
        }

        static func open(
            command: SSHMasterCommand, executable: URL, signIn: SignIn? = nil, knownHostsName: String? = nil,
            poll: Duration = .milliseconds(100), limit: Duration = .seconds(60),
            ceiling: Duration = .seconds(300)
        ) async throws(TransportError) -> SystemSSHConnection {
            if Task.isCancelled { throw .cancelled }
            let handle = MasterHandle()
            var bridge: AskpassBridge?
            var environment: [String: String] = [:]
            if let signIn {
                let token = AskpassBridge.newToken()
                let made = makeBridge(signIn, token: token, command: command, handle: handle)
                try made.listen()
                environment = [
                    "SSH_ASKPASS": signIn.helper.path, "SSH_ASKPASS_REQUIRE": "force",
                    AskpassWire.socketVariable: made.path,
                    AskpassWire.tokenVariable: AskpassWire.tokenText(token),
                ]
                bridge = made
            }
            let master: ProcessConnection
            do {
                master = try ProcessConnection.launch(
                    executable: executable, arguments: command.master, environment: environment,
                    logsStderr: bridge == nil, classify: SSHErrorClassifier.classify)
            } catch {
                bridge?.revoke()
                throw error
            }
            handle.set(master)
            bridge?.serve()
            let connection = SystemSSHConnection(command: command, executable: executable, master: master)
            Task { await connection.watch() }
            do throws(TransportError) {
                try await connection.waitUntilReady(
                    poll: poll, limit: limit, ceiling: ceiling, asking: bridge)
            } catch {
                let outcome = bridge?.outcome
                bridge?.revoke()
                await connection.close()
                throw failure(error, outcome: outcome, knownHostsName: knownHostsName)
            }
            bridge?.revoke()
            log.info("master ready")
            return connection
        }

        /// The bridge beside the master's socket, open only to `signIn`'s helper under its ssh.
        private static func makeBridge(
            _ signIn: SignIn, token: [UInt8], command: SSHMasterCommand, handle: MasterHandle
        ) -> AskpassBridge {
            let questions = signIn.questions
            return AskpassBridge(
                path: ControlSocketDirectory.bridgePath(forMaster: command.socket), token: token,
                destination: command.target.value, names: signIn.names,
                peer: AskpassPeer(helper: signIn.helper.path, ssh: signIn.ssh, masterPID: { handle.pid }),
                ask: { await questions.ask($0) }, end: { await handle.end() })
        }

        /// The bridge's outcome names the failure over ssh's own words; a changed key's
        /// known_hosts name is the probe's, and none through a jump host, whose ssh may be the
        /// one whose key changed.
        static func failure(_ error: TransportError, outcome: AskpassBridge.Outcome?, knownHostsName: String?)
            -> TransportError
        {
            guard case .exited(let status, let failure) = error, failure != .signInTimedOut else {
                return error
            }
            switch outcome {
            case .denied: return .exited(status: status, failure: .hostKeyDenied)
            case .cancelled: return .exited(status: status, failure: .signInCancelled)
            case .tooMany: return .exited(status: status, failure: .tooManyQuestions)
            case nil:
                guard case .changedHostKey(let fingerprint, nil) = failure else { return error }
                return .exited(
                    status: status,
                    failure: .changedHostKey(fingerprint: fingerprint, knownHostsName: knownHostsName))
            }
        }

        /// The master, for the bridge: its pid for the peer check, and ending it.
        private final class MasterHandle: Sendable {
            private let master = Mutex<ProcessConnection?>(nil)
            var pid: pid_t? { master.withLock { $0?.processIdentifier } }
            func set(_ connection: ProcessConnection) { master.withLock { $0 = connection } }
            func end() async { await master.withLock { $0 }?.end() }
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
        /// exit, a cancel, `limit` of time with no question open, or `ceiling` in all (the master
        /// is then ended) first ends the wait.
        private func waitUntilReady(
            poll: Duration, limit: Duration, ceiling: Duration, asking: AskpassBridge?
        )
            async throws(TransportError)
        {
            let start = ContinuousClock.now
            var (counted, last) = (Duration.zero, start)
            while counted < limit, last - start < ceiling {
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
                let now = ContinuousClock.now
                if asking?.questionOpen != true { counted += now - last }
                last = now
            }
            master.terminate()
            throw .exited(status: 255, failure: .signInTimedOut)
        }
    }
#endif
