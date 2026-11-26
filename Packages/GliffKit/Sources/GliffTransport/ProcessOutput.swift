#if os(macOS)
    import Foundation

    /// A one-shot program's stdout, read to its end within a size and a time limit. The
    /// process is ended (too much, too late, or no longer wanted) and reaped before the answer
    /// comes back.
    enum ProcessOutput {
        enum Failure: Error, Equatable {
            case notStarted
            case failed(ConnectFailure)
            case timedOut
            case tooLarge
            case unreadable
            /// Cancelled before the program was started.
            case cancelled
        }

        static func read(
            executable: URL, arguments: [String], maxBytes: Int, timeout: Duration, logsStderr: Bool = true,
            classify: @escaping @Sendable (Int32, String) -> ConnectFailure = SSHErrorClassifier.classify
        ) async -> Result<[UInt8], Failure> {
            await run(
                executable: executable, arguments: arguments, maxBytes: maxBytes, timeout: timeout,
                logsStderr: logsStderr, classify: classify
            ).outcome
        }

        /// How a program ended: its status and the end of its stderr.
        struct Exit: Equatable {
            let status: Int32
            let stderr: String
        }

        /// A program's exit status and stderr, whatever the status, within `timeout`; its stdout
        /// is read and dropped, and its stderr never logged.
        static func exit(executable: URL, arguments: [String], timeout: Duration) async -> Result<
            Exit, Failure
        > {
            let ran = await run(
                executable: executable, arguments: arguments, maxBytes: 4096, timeout: timeout,
                logsStderr: false, classify: SSHErrorClassifier.classify)
            switch ran.outcome {
            case .success, .failure(.failed):
                guard let connection = ran.connection, let status = connection.exitStatus else {
                    return .failure(.unreadable)
                }
                return .success(
                    Exit(status: status, stderr: String(decoding: connection.stderrTail, as: UTF8.self)))
            case .failure(let failure): return .failure(failure)
            }
        }

        /// Launches the program and collects its output; the process is ended if the output
        /// isn't wanted, and reaped, before the answer comes back.
        private static func run(
            executable: URL, arguments: [String], maxBytes: Int, timeout: Duration, logsStderr: Bool,
            classify: @escaping @Sendable (Int32, String) -> ConnectFailure
        ) async -> (outcome: Result<[UInt8], Failure>, connection: ProcessConnection?) {
            if Task.isCancelled { return (.failure(.cancelled), nil) }
            let connection: ProcessConnection
            do {
                connection = try ProcessConnection.launch(
                    executable: executable, arguments: arguments, logsStderr: logsStderr, classify: classify)
            } catch {
                return (.failure(.notStarted), nil)
            }
            let outcome = await collect(connection, maxBytes: maxBytes, timeout: timeout)
            if Task.isCancelled || (try? outcome.get()) == nil { connection.terminate() }
            await connection.close()
            return (outcome, connection)
        }

        /// Any connection's output, as a program's is read (a channel on a shared connection);
        /// the connection is closed before the answer comes back.
        static func read(_ connection: any ByteConnection, maxBytes: Int, timeout: Duration) async
            -> Result<[UInt8], Failure>
        {
            let outcome = await collect(connection, maxBytes: maxBytes, timeout: timeout)
            await connection.close()
            return outcome
        }

        /// The output, or why there is none: whichever of the end, the limit and the timer comes
        /// first.
        private static func collect(_ connection: any ByteConnection, maxBytes: Int, timeout: Duration) async
            -> Result<[UInt8], Failure>
        {
            await withTaskGroup(of: Result<[UInt8], Failure>.self) { group in
                group.addTask {
                    var bytes: [UInt8] = []
                    do {
                        for try await chunk in connection.incoming {
                            bytes += chunk
                            if bytes.count > maxBytes { return .failure(.tooLarge) }
                        }
                        return .success(bytes)
                    } catch TransportError.exited(_, let failure) {
                        return .failure(.failed(failure))
                    } catch {
                        return .failure(.unreadable)
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return .failure(.timedOut)
                }
                let first = await group.next() ?? .failure(.timedOut)
                group.cancelAll()
                return first
            }
        }
    }
#endif
