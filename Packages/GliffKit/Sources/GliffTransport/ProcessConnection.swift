#if os(macOS)
    import Foundation
    import Synchronization
    import os

    /// A running process as a `ByteConnection`.
    ///
    /// - Pipes are read and written with `DispatchIO` on one serial queue, so no blocking call
    ///   runs on the cooperative thread pool, and reading and writing never wait on each other.
    /// - `incoming` ends once stdout and stderr have closed and the process has exited. If a
    ///   grandchild keeps a pipe open after the process exits, the pipes are closed 1 s later.
    /// - `close()`: close stdin, wait 2 s, SIGTERM, wait 1 s, SIGKILL; it returns once the
    ///   process has been reaped (an error is logged if even SIGKILL doesn't end it in 5 s).
    ///   Waits are timers, not polling, and ignore task cancellation: closing from a cancelled
    ///   task still gives the process its time.
    /// - If whoever iterates `incoming` stops (cancelled), the connection closes itself, so a
    ///   forgotten `close()` can't leave ssh running.
    /// - A process killed by a signal reports the signal as a negative status.
    final class ProcessConnection: ByteConnection {
        let incoming: AsyncThrowingStream<[UInt8], any Error>

        private static let stderrLimit = 16 * 1024
        private static let log = Logger(subsystem: "me.cbyrd.Glifftop", category: "GliffTransport")

        private struct State {
            var stdoutDone = false
            var stderrDone = false
            var exitStatus: Int32?
            var stderrTail: [UInt8] = []
            var stdinClosed = false
            /// close() was called while the process ran: its ending is expected, not a failure.
            var closing = false
            var finished = false
            var exitWaiters: [ExitWaiter] = []
        }

        /// One `waitForExit` call: resumed once, by the exit or by its timer.
        private final class ExitWaiter: Sendable {
            private let continuation: Mutex<CheckedContinuation<Bool, Never>?>

            init(_ continuation: CheckedContinuation<Bool, Never>) {
                self.continuation = Mutex(continuation)
            }

            func resume(exited: Bool) {
                continuation.withLock { $0.take() }?.resume(returning: exited)
            }
        }

        private let process: Process
        private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
        private let classify: @Sendable (Int32, String) -> ConnectFailure
        private let logsStderr: Bool
        private let queue = DispatchQueue(label: "me.cbyrd.Glifftop.process")
        private let stdin: DispatchIO
        private let stdout: DispatchIO
        private let stderr: DispatchIO
        private let state = Mutex(State())

        /// `environment` adds to the app's own. `logsStderr: false` keeps the stderr tail out of
        /// the log (a master that may ask: its stderr can hold the host's sign-in text).
        static func launch(
            executable: URL, arguments: [String], environment: [String: String] = [:],
            logsStderr: Bool = true,
            classify: @escaping @Sendable (Int32, String) -> ConnectFailure
        ) throws(TransportError) -> ProcessConnection {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            }
            let connection = ProcessConnection(process: process, logsStderr: logsStderr, classify: classify)
            do {
                try process.run()
            } catch {
                log.error(
                    "launch failed: \(executable.path, privacy: .public): \(error.localizedDescription)")
                connection.discardUnstarted()
                throw .launchFailed(error.localizedDescription)
            }
            log.debug("launched \(executable.path, privacy: .public), pid \(process.processIdentifier)")
            return connection
        }

        /// Wires the pipes and handlers; `launch` then runs the process.
        private init(
            process: Process, logsStderr: Bool,
            classify: @escaping @Sendable (Int32, String) -> ConnectFailure
        ) {
            let (stdinPipe, stdoutPipe, stderrPipe) = (Pipe(), Pipe(), Pipe())
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            // A write after the process has gone fails with EPIPE instead of killing the app.
            _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

            self.process = process
            self.classify = classify
            self.logsStderr = logsStderr
            (incoming, continuation) = AsyncThrowingStream.makeStream()
            stdin = Self.channel(stdinPipe.fileHandleForWriting, queue: queue)
            stdout = Self.channel(stdoutPipe.fileHandleForReading, queue: queue)
            stderr = Self.channel(stderrPipe.fileHandleForReading, queue: queue)

            // Set before run(), so even an instant exit is seen.
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                self?.processExited(status: process.terminationReason == .uncaughtSignal ? -status : status)
            }
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination, let self else { return }
                Task { await self.close() }
            }
            read(stdout) { [continuation] bytes in
                continuation.yield(bytes)
            } ended: {
                $0.stdoutDone = true
            }
            read(stderr) { [self] bytes in
                self.state.withLock { state in
                    state.stderrTail += bytes
                    // Trimmed in batches, so a chatty process doesn't cost a shift per chunk.
                    if state.stderrTail.count > 2 * Self.stderrLimit {
                        state.stderrTail.removeFirst(state.stderrTail.count - Self.stderrLimit)
                    }
                }
            } ended: {
                $0.stderrDone = true
            }
        }

        /// The process didn't start: release the pipes and end `incoming`.
        private func discardUnstarted() {
            state.withLock { $0.finished = true }
            for io in [stdin, stdout, stderr] { io.close(flags: .stop) }
            continuation.finish()
        }

        /// The pid, once launched.
        var processIdentifier: Int32 { process.processIdentifier }

        /// A stream channel on `handle`'s descriptor; the handle is closed when the channel is.
        private static func channel(_ handle: FileHandle, queue: DispatchQueue) -> DispatchIO {
            let io = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
                try? handle.close()
            }
            io.setLimit(lowWater: 1)
            return io
        }

        private func read(
            _ io: DispatchIO, chunk: @escaping @Sendable ([UInt8]) -> Void,
            ended: @escaping @Sendable (inout State) -> Void
        ) {
            io.read(offset: 0, length: .max, queue: queue) { [self] done, data, _ in
                if let data, !data.isEmpty { chunk([UInt8](data)) }
                guard done else { return }
                io.close()
                state.withLock { ended(&$0) }
                finishIfDone()
            }
        }

        /// The stderr kept so far, for tests.
        var stderrTail: [UInt8] { state.withLock { $0.stderrTail } }
        /// The exit status once the process has exited (negative: the signal), for tests.
        var exitStatus: Int32? { state.withLock { $0.exitStatus } }

        func write(_ bytes: [UInt8]) async throws(TransportError) {
            guard !bytes.isEmpty else { return }
            let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
            let error: Int32 = await withCheckedContinuation { result in
                queue.async { [self] in
                    guard !state.withLock(\.stdinClosed) else { return result.resume(returning: EPIPE) }
                    stdin.write(offset: 0, data: data, queue: queue) { done, _, error in
                        if done { result.resume(returning: error) }
                    }
                }
            }
            if error != 0 { throw .writeFailed(String(cString: strerror(error))) }
        }

        func close() async {
            // An exit that already happened keeps its own status: it wasn't caused by close().
            state.withLock { state in
                if state.exitStatus == nil { state.closing = true }
            }
            closeStdin()
            if await waitForExit(within: .seconds(2)) { return }
            Self.log.debug("pid \(self.processIdentifier) still running after stdin closed")
            await end()
        }

        /// Ends the process now and returns once it has exited: SIGTERM, then SIGKILL after 1 s,
        /// each to its whole group (`terminate()`).
        func end() async {
            terminate()
            if await waitForExit(within: .seconds(1)) { return }
            // isRunning turns false when Foundation reaps the child, so a signal never goes
            // to a recycled pid (short of the instant between this check and the signal).
            if process.isRunning {
                Self.log.debug("pid \(self.processIdentifier) still running after SIGTERM: SIGKILL")
                if killpg(processIdentifier, SIGKILL) != 0 { kill(processIdentifier, SIGKILL) }
            }
            if await !waitForExit(within: .seconds(5)) {
                Self.log.error("pid \(self.processIdentifier) survived SIGKILL for 5 s")
            }
        }

        /// Ends the process now (SIGTERM), without `close()`'s wait on stdin: for a one-shot
        /// command whose answer is no longer wanted, so its output stops piling up. `close()`
        /// still reaps it.
        ///
        /// Foundation starts each process as its own process group's leader, and the whole group
        /// is ended (`endGroup`): an ssh's ProxyJump or ProxyCommand children and its askpass
        /// helpers end with it. A process that has left its group is signalled by itself.
        func terminate() {
            state.withLock { state in
                if state.exitStatus == nil { state.closing = true }
            }
            // isRunning turns false when Foundation reaps the child: the group is still its own.
            guard process.isRunning else { return }
            if !Self.endGroup(processIdentifier) { kill(processIdentifier, SIGTERM) }
        }

        /// Sends `group` SIGTERM while it is stopped, and whether it could. The kernel signals a
        /// group's newest member first, and a member running between two of them could act on
        /// the other's end: an ssh woken by its askpass helper's exit sends an empty answer.
        /// Stopped, none of it runs until all of it has the signal; continued, a member whose
        /// SIGTERM does the default (ssh's, while it waits on a helper) ends before running any
        /// code, and one that catches it runs its handler.
        @discardableResult
        static func endGroup(
            _ group: pid_t, signal: (pid_t, Int32) -> Int32 = { killpg($0, $1) }
        ) -> Bool {
            _ = signal(group, SIGSTOP)
            let sent = signal(group, SIGTERM) == 0
            _ = signal(group, SIGCONT)
            return sent
        }

        private func closeStdin() {
            queue.async { [self] in
                let wasClosed = state.withLock { state in
                    let wasClosed = state.stdinClosed
                    state.stdinClosed = true
                    return wasClosed
                }
                // .stop: a write the process isn't reading fails now instead of holding EOF back.
                if !wasClosed { stdin.close(flags: .stop) }
            }
        }

        /// Whether the process has exited (and been reaped) within `limit`. A timer, not the
        /// task's sleep: it works the same from a cancelled task.
        private func waitForExit(within limit: Duration) async -> Bool {
            await withCheckedContinuation { continuation in
                let waiter = ExitWaiter(continuation)
                let exited = state.withLock { state in
                    if state.exitStatus == nil { state.exitWaiters.append(waiter) }
                    return state.exitStatus != nil
                }
                if exited { return waiter.resume(exited: true) }
                let (seconds, attoseconds) = limit.components
                let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
                queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) {
                    waiter.resume(exited: false)
                }
            }
        }

        private func processExited(status: Int32) {
            Self.log.debug("pid \(self.processIdentifier) exited with status \(status)")
            let waiters = state.withLock { state in
                state.exitStatus = status
                defer { state.exitWaiters = [] }
                return state.exitWaiters
            }
            for waiter in waiters { waiter.resume(exited: true) }
            finishIfDone()
            // A grandchild may hold the pipes open after the process is gone.
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                stdout.close(flags: .stop)
                stderr.close(flags: .stop)
            }
            closeStdin()
        }

        /// Ends `incoming` once stdout, stderr and the process are all done.
        private func finishIfDone() {
            let outcome: (status: Int32, closing: Bool, stderr: String)? = state.withLock { state in
                guard state.stdoutDone, state.stderrDone, let status = state.exitStatus, !state.finished
                else {
                    return nil
                }
                state.finished = true
                return (
                    status, state.closing,
                    String(decoding: state.stderrTail.suffix(Self.stderrLimit), as: UTF8.self)
                )
            }
            guard let outcome else { return }
            if outcome.status == 0 || outcome.closing {
                continuation.finish()
            } else {
                if logsStderr { Self.log.debug("stderr tail: \(outcome.stderr, privacy: .private)") }
                let failure = classify(outcome.status, outcome.stderr)
                continuation.finish(throwing: TransportError.exited(status: outcome.status, failure: failure))
            }
        }
    }
#endif
