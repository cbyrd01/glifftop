#if os(macOS)
    public import Foundation

    /// Runs `ScreenListCommand` and reads the host's monitors: stdout to its end, at
    /// most `ScreenListParser.maxBytes`, within a time limit long enough for a 1Password
    /// approval. The process is ended and reaped before an answer comes back.
    public struct ScreenLister: Sendable {
        let executable: URL
        let arguments: [String]
        let timeout: Duration

        public init(command: ScreenListCommand) {
            self.init(
                executable: URL(filePath: SSHCommand.executable), arguments: command.arguments,
                timeout: .seconds(60))
        }

        init(executable: URL, arguments: [String], timeout: Duration) {
            (self.executable, self.arguments, self.timeout) = (executable, arguments, timeout)
        }

        public func screens() async throws(ScreenListError) -> [RemoteScreen] {
            let connection: ProcessConnection
            do {
                connection = try ProcessConnection.launch(
                    executable: executable, arguments: arguments, classify: Self.classify)
            } catch {
                throw .failed(.other("ssh couldn't be started."))
            }
            let outcome = await read(connection)
            // Too much, too late or no longer wanted: stop it now rather than wait on it.
            if Task.isCancelled || (try? outcome.get()) == nil { connection.terminate() }
            await connection.close()
            if Task.isCancelled { throw .cancelled }
            return try ScreenListParser.screens(from: outcome.get())
        }

        /// stdout, or why there is none: whichever of the end, the limit and the timer comes first.
        private func read(_ connection: ProcessConnection) async -> Result<[UInt8], ScreenListError> {
            await withTaskGroup(of: Result<[UInt8], ScreenListError>.self) { group in
                group.addTask {
                    var bytes: [UInt8] = []
                    do {
                        for try await chunk in connection.incoming {
                            bytes += chunk
                            if bytes.count > ScreenListParser.maxBytes { return .failure(.tooLarge) }
                        }
                        return .success(bytes)
                    } catch TransportError.exited(_, let failure) {
                        return .failure(.failed(failure))
                    } catch {
                        return .failure(.unreadable)
                    }
                }
                group.addTask { [timeout] in
                    try? await Task.sleep(for: timeout)
                    return .failure(.timedOut)
                }
                let first = await group.next() ?? .failure(.timedOut)
                group.cancelAll()
                return first
            }
        }

        /// ssh's own failures as for a session; the shell's "command not found" names hyprctl.
        private static func classify(exitStatus: Int32, stderr: String) -> ConnectFailure {
            if exitStatus == 127 && stderr.contains("hyprctl") {
                return .other("hyprctl isn't installed on the host, or isn't on its PATH.")
            }
            return SSHErrorClassifier.classify(exitStatus: exitStatus, stderr: stderr)
        }
    }
#endif
