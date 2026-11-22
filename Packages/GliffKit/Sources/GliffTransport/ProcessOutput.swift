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
            executable: URL, arguments: [String], maxBytes: Int, timeout: Duration,
            classify: @escaping @Sendable (Int32, String) -> ConnectFailure = SSHErrorClassifier.classify
        ) async -> Result<[UInt8], Failure> {
            if Task.isCancelled { return .failure(.cancelled) }
            let connection: ProcessConnection
            do {
                connection = try ProcessConnection.launch(
                    executable: executable, arguments: arguments, classify: classify)
            } catch {
                return .failure(.notStarted)
            }
            let outcome = await read(connection, maxBytes: maxBytes, timeout: timeout)
            if Task.isCancelled || (try? outcome.get()) == nil { connection.terminate() }
            await connection.close()
            return outcome
        }

        /// stdout, or why there is none: whichever of the end, the limit and the timer comes first.
        private static func read(_ connection: ProcessConnection, maxBytes: Int, timeout: Duration) async
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
