#if os(macOS)
    public import Foundation

    /// Runs `ScreenListCommand` and reads the host's monitors: stdout to its end, at
    /// most `ScreenListParser.maxBytes`, within a time limit long enough for a 1Password
    /// approval, with a connect timeout where `SSHConnectTimeout` finds one wanted. The
    /// process is ended and reaped before an answer comes back.
    public struct ScreenLister: Sendable {
        let executable: URL
        let arguments: @Sendable () async -> [String]
        let timeout: Duration

        public init(command: ScreenListCommand) {
            (executable, timeout) = (URL(filePath: SSHCommand.executable), .seconds(60))
            arguments = {
                var command = command
                command.connectTimeout = await SSHConnectTimeout.isWanted(
                    sshArguments: command.sshArguments, target: command.target)
                return command.arguments
            }
        }

        init(executable: URL, arguments: [String], timeout: Duration) {
            (self.executable, self.arguments, self.timeout) = (executable, { arguments }, timeout)
        }

        public func screens() async throws(ScreenListError) -> [RemoteScreen] {
            let output = await ProcessOutput.read(
                executable: executable, arguments: arguments(), maxBytes: ScreenListParser.maxBytes,
                timeout: timeout, classify: Self.classify)
            if Task.isCancelled { throw .cancelled }
            switch output {
            case .success(let bytes): return try ScreenListParser.screens(from: bytes)
            case .failure(.notStarted): throw .failed(.other("ssh couldn't be started."))
            case .failure(.failed(let failure)): throw .failed(failure)
            case .failure(.timedOut): throw .timedOut
            case .failure(.tooLarge): throw .tooLarge
            case .failure(.unreadable): throw .unreadable
            case .failure(.cancelled): throw .cancelled
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
