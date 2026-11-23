#if os(macOS)
    public import Foundation

    /// Runs `ScreenListCommand` and reads the host's monitors: the output to its end, at most
    /// `ScreenListParser.maxBytes`, within a time limit long enough for a 1Password approval.
    /// The app's lister runs it as a channel on the host's shared connection; the other runs one
    /// ssh, with a connect timeout where `SSHConnectTimeout` finds one wanted. Either is ended
    /// before an answer comes back.
    public struct ScreenLister: Sendable {
        private enum Source {
            case process(executable: URL, arguments: @Sendable () async -> [String])
            case channel(ChannelTransport)
        }

        private let source: Source
        private let timeout: Duration

        public init(command: ScreenListCommand) {
            let arguments: @Sendable () async -> [String] = {
                var command = command
                command.connectTimeout = await SSHConnectTimeout.isWanted(
                    sshArguments: command.sshArguments, target: command.target)
                return command.arguments
            }
            source = .process(executable: URL(filePath: SSHCommand.executable), arguments: arguments)
            timeout = .seconds(60)
        }

        /// On `connections`' shared connection to `target`, as the person's own try (it asks
        /// for a sign-in again). The list comes only at the script's end, so the channel's
        /// first-byte watchdog waits as long as the listing may.
        public init(
            connections: HostConnections, target: SSHTarget, timeout: Duration = .seconds(60),
            clock: any Clock<Duration> = ContinuousClock()
        ) {
            let command = ScreenListCommand(target: target).remoteCommand
            source = .channel(
                ChannelTransport(
                    connections: connections, target: target, command: command, silenceLimit: timeout,
                    fresh: true, clock: clock))
            self.timeout = timeout
        }

        init(executable: URL, arguments: [String], timeout: Duration) {
            source = .process(executable: executable, arguments: { arguments })
            self.timeout = timeout
        }

        public func screens() async throws(ScreenListError) -> [RemoteScreen] {
            let output = await read()
            if Task.isCancelled { throw .cancelled }
            switch output {
            case .success(let bytes): return try ScreenListParser.screens(from: bytes)
            case .failure(.notStarted): throw .failed(.other("ssh couldn't be started."))
            case .failure(.failed(let failure)): throw .failed(Self.named(failure))
            case .failure(.timedOut): throw .timedOut
            case .failure(.tooLarge): throw .tooLarge
            case .failure(.unreadable): throw .unreadable
            case .failure(.cancelled): throw .cancelled
            }
        }

        private func read() async -> Result<[UInt8], ProcessOutput.Failure> {
            switch source {
            case .process(let executable, let arguments):
                return await ProcessOutput.read(
                    executable: executable, arguments: arguments(), maxBytes: ScreenListParser.maxBytes,
                    timeout: timeout)
            case .channel(let transport):
                let channel: any ByteConnection
                do {
                    channel = try await transport.connect()
                } catch .cancelled {
                    return .failure(.cancelled)
                } catch .exited(_, let failure) {
                    return .failure(.failed(failure))
                } catch .launchFailed(let reason) {
                    return .failure(.failed(.other(reason)))
                } catch {
                    return .failure(.notStarted)
                }
                return await ProcessOutput.read(
                    channel, maxBytes: ScreenListParser.maxBytes, timeout: timeout)
            }
        }

        /// A shell's "command not found" for hyprctl (or the script's own line) names it plainly.
        private static func named(_ failure: ConnectFailure) -> ConnectFailure {
            guard case .other(let line) = failure, line.hasSuffix("hyprctl: command not found") else {
                return failure
            }
            return .other("hyprctl isn't installed on the host, or isn't on its PATH.")
        }
    }
#endif
