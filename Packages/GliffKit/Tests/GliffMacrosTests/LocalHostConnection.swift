#if os(macOS)
    import Darwin
    import Foundation
    import GliffTestSupport
    import GliffTransport
    import Synchronization
    import os

    /// A `HostConnection` whose channels run their command line as sshd does, with a local shell
    /// as the login shell: `<shell> -c <command>` in a session of its own, so the wrapper's
    /// `kill 0` reaches only the run, with default signals and stdin, stdout and stderr on pipes.
    ///
    /// - A channel's `close()` only closes its stdin. It never signals the process or its group,
    ///   so only the wrapper can end a script.
    /// - `killLeftovers()` ends every group the connection started; the suite's teardown calls
    ///   it, after the checks.
    final class LocalHostConnection: HostConnection {
        private struct State {
            var groups: [pid_t] = []
            var ended = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        let shell: String
        /// The whole environment but a default `PATH`: none of the test process's own, so no
        /// `ZDOTDIR`, `BASH_ENV` or `ENV` of the person running the tests reaches a shell.
        let environment: [String: String]
        private let state = Mutex(State())

        init(shell: String = "/bin/sh", environment: [String: String] = [:]) {
            (self.shell, self.environment) = (shell, environment)
        }

        func channel(command: String, logsStderr: Bool) async throws(TransportError) -> any ByteConnection {
            try localChannel(command: command, logsStderr: logsStderr)
        }

        /// As `channel(command:logsStderr:)`, typed, for the checks that need its pid or status.
        func localChannel(command: String, logsStderr: Bool = false) throws(TransportError) -> LocalChannel {
            let variables = (["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]).merging(environment) { $1 }
            let channel = try LocalChannel(
                arguments: [shell, "-c", command], environment: variables.map { "\($0)=\($1)" },
                logsStderr: logsStderr)
            state.withLock { $0.groups.append(channel.pid) }
            return channel
        }

        /// Returns nil once `close()` or `invalidate()` has been called: a local connection is never
        /// lost.
        func ended() async -> ConnectFailure? {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let done = state.withLock { state in
                    if !state.ended { state.waiters.append(continuation) }
                    return state.ended
                }
                if done { continuation.resume() }
            }
            return nil
        }

        func invalidate() async { await close() }

        func close() async {
            let waiters = state.withLock { state in
                state.ended = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }

        /// SIGKILL to every group this connection started.
        func killLeftovers() {
            for group in state.withLock({ $0.groups }) { kill(-group, SIGKILL) }
        }
    }

    /// One local run: `incoming` ends as `ProcessConnection`'s does, once stdout and stderr have
    /// closed and the process has exited, normally after `close()` or a status of 0, else with
    /// `TransportError.exited` and the channel's classified failure.
    final class LocalChannel: ByteConnection {
        let incoming: AsyncThrowingStream<[UInt8], any Error>
        /// The login shell's pid, which is also its session's and group's id.
        let pid: pid_t
        private let stdin: OSAllocatedUnfairLock<Int32?>
        private let state = OSAllocatedUnfairLock(
            initialState: (stderr: [UInt8](), status: Int32?.none, closedFirst: false))
        private let exited = DispatchGroup()

        fileprivate init(arguments: [String], environment: [String], logsStderr: Bool) throws(TransportError)
        {
            let (input, output, errors) = (Self.pipe(), Self.pipe(), Self.pipe())
            _ = fcntl(input.write, F_SETNOSIGPIPE, 1)
            let spawned = Self.spawn(
                arguments, environment, stdin: input.read, stdout: output.write, stderr: errors.write)
            for fd in [input.read, output.write, errors.write] { Darwin.close(fd) }
            guard let pid = spawned else {
                for fd in [input.write, output.read, errors.read] { Darwin.close(fd) }
                throw .launchFailed("posix_spawn failed")
            }
            self.pid = pid
            self.stdin = OSAllocatedUnfairLock<Int32?>(initialState: input.write)
            let (incoming, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
            self.incoming = incoming
            let parts = DispatchGroup()
            for _ in 0..<3 { parts.enter() }
            exited.enter()
            let state = state
            Self.reading(output.read, parts) { continuation.yield($0) }
            Self.reading(errors.read, parts) { bytes in state.withLock { $0.stderr += bytes } }
            Thread.detachNewThread { [exited] in
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                let code = status & 0x7f == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
                state.withLock { $0.status = code }
                exited.leave()
                parts.leave()
            }
            parts.notify(queue: .global()) {
                let (code, stderr, closed) = state.withLock { ($0.status ?? 0, $0.stderr, $0.closedFirst) }
                let classify = SSHErrorClassifier.channelClassifier(logsStderr: logsStderr)
                let error = TransportError.end(status: code, closedFirst: closed) {
                    classify(code, String(decoding: stderr, as: UTF8.self))
                }
                continuation.finish(throwing: error)
            }
        }

        /// What the process wrote on stderr so far.
        var stderr: String { String(decoding: state.withLock { $0.stderr }, as: UTF8.self) }

        /// The login shell's exit status (a signal as a negative number), once it has exited.
        func exitStatus() async -> Int32 {
            await withCheckedContinuation { done in exited.notify(queue: .global()) { done.resume() } }
            return state.withLock { $0.status ?? 0 }
        }

        /// Writes on a copy of stdin's descriptor, so a write blocked on a full pipe never holds
        /// up `close()`.
        func write(_ bytes: [UInt8]) async throws(TransportError) {
            guard let fd = stdin.withLock({ $0.map { dup($0) } }), fd >= 0 else {
                throw .writeFailed("stdin is closed")
            }
            let written = await onThread {
                defer { Darwin.close(fd) }
                var offset = 0
                while offset < bytes.count {
                    let count = bytes[offset...].withUnsafeBytes {
                        Darwin.write(fd, $0.baseAddress, $0.count)
                    }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            if !written { throw .writeFailed("stdin is closed") }
        }

        deinit { closeStdin() }

        /// Closes stdin and nothing else. A close before the exit makes the end a clean finish,
        /// as `ProcessConnection`'s does; after it, the exit's failure stands.
        func close() async {
            state.withLock { if $0.status == nil { $0.closedFirst = true } }
            closeStdin()
        }

        private func closeStdin() {
            stdin.withLock { fd in
                if let fd { Darwin.close(fd) }
                fd = nil
            }
        }

        private static func pipe() -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            precondition(Darwin.pipe(&fds) == 0, "pipe failed")
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (fds[0], fds[1])
        }

        /// Reads `fd` to its end on a thread of its own, then closes it.
        private static func reading(
            _ fd: Int32, _ parts: DispatchGroup, _ chunk: @escaping @Sendable ([UInt8]) -> Void
        ) {
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    chunk(Array(buffer[..<count]))
                }
                Darwin.close(fd)
                parts.leave()
            }
        }

        private static func spawn(
            _ arguments: [String], _ environment: [String], stdin: Int32, stdout: Int32, stderr: Int32
        ) -> pid_t? {
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
            posix_spawn_file_actions_adddup2(&actions, stdout, 1)
            posix_spawn_file_actions_adddup2(&actions, stderr, 2)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            var all = sigset_t()
            sigfillset(&all)
            var none = sigset_t()
            sigemptyset(&none)
            posix_spawnattr_setsigdefault(&attributes, &all)
            posix_spawnattr_setsigmask(&attributes, &none)
            let flags =
                POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
            posix_spawnattr_setflags(&attributes, Int16(flags))
            let argv = arguments.map { strdup($0) } + [nil]
            let envp = environment.map { strdup($0) } + [nil]
            defer { for pointer in argv + envp { free(pointer) } }
            var pid: pid_t = 0
            let result = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)
            return result == 0 ? pid : nil
        }
    }
#endif
