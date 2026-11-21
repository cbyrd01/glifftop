#if os(macOS)
    import Darwin
    import Foundation
    import Testing

    @testable import GliffTransport

    /// Runs Apple's own binaries (/bin/cat, /bin/sh) as stand-ins for ssh.
    @Suite(.timeLimit(.minutes(1))) struct ProcessTransportTests {
        private func connect(_ executable: String, _ arguments: [String] = []) async throws
            -> ProcessConnection
        {
            let transport = ProcessTransport(executable: URL(filePath: executable), arguments: arguments)
            return try #require(try await transport.connect() as? ProcessConnection)
        }

        private func shell(_ script: String) async throws -> ProcessConnection {
            try await connect("/bin/sh", ["-c", script])
        }

        /// Everything `incoming` yields until it ends, and the error it ended with, if any.
        private func drain(_ connection: ProcessConnection) async -> (bytes: [UInt8], error: (any Error)?) {
            var bytes: [UInt8] = []
            do {
                for try await chunk in connection.incoming { bytes += chunk }
                return (bytes, nil)
            } catch {
                return (bytes, error)
            }
        }

        /// User plus system CPU time of this test process so far.
        private func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
            return seconds(usage.ru_utime) + seconds(usage.ru_stime)
        }

        /// Whether process `pid` is gone within `limit`.
        private func exits(_ pid: Int32, within limit: Duration) async -> Bool {
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                if kill(pid, 0) == -1 && errno == ESRCH { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }

        @Test func echoRoundTrip() async throws {
            let connection = try await connect("/bin/cat")
            try await connection.write([1, 2, 3])
            var received: [UInt8] = []
            for try await chunk in connection.incoming {
                received += chunk
                if received.count >= 3 { break }
            }
            #expect(received.starts(with: [1, 2, 3]))
            await connection.close()
        }

        /// Writing and reading at the same time never deadlocks on a full pipe.
        @Test func eightMegabytesBothWays() async throws {
            let connection = try await connect("/bin/cat")
            let sent = (0..<(8 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
            let writer = Task {
                var start = 0
                while start < sent.count {
                    let end = min(start + 256 * 1024, sent.count)
                    try await connection.write(Array(sent[start..<end]))
                    start = end
                }
            }
            var received: [UInt8] = []
            received.reserveCapacity(sent.count)
            for try await chunk in connection.incoming {
                received += chunk
                if received.count >= sent.count { break }
            }
            try await writer.value
            #expect(received == sent)
            await connection.close()
        }

        @Test func cleanExitFinishesStream() async throws {
            let connection = try await connect("/bin/cat")
            await connection.close()
            let result = await drain(connection)
            #expect(result.error == nil)
        }

        @Test func failureIsClassified() async throws {
            let connection = try await shell("echo 'Permission denied (publickey).' >&2; exit 255")
            let result = await drain(connection)
            #expect(result.error as? TransportError == .exited(status: 255, failure: .permissionDenied))
        }

        /// Only the tail of stderr is kept: a chatty process can't grow memory without bound.
        @Test func stderrTailIsBounded() async throws {
            let connection = try await shell(
                "head -c 102400 /dev/zero | tr '\\0' x >&2; echo >&2; echo 'last line' >&2; exit 1")
            let result = await drain(connection)
            #expect(result.error as? TransportError == .exited(status: 1, failure: .other("last line")))
            #expect(connection.stderrTail.count <= 2 * 16 * 1024)
        }

        /// Close() ends even a process that ignores SIGTERM, and reaps it.
        @Test func closeKillsAStubbornProcess() async throws {
            let connection = try await shell("trap '' TERM; while :; do sleep 1; done")
            let pid = connection.processIdentifier
            let clock = ContinuousClock()
            let elapsed = await clock.measure { await connection.close() }
            #expect(elapsed < .seconds(5))
            errno = 0
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
        }

        @Test func closeIsIdempotent() async throws {
            let connection = try await connect("/bin/cat")
            await connection.close()
            await connection.close()
        }

        @Test func writeAfterExitFails() async throws {
            let connection = try await shell("exit 0")
            _ = await drain(connection)
            await #expect(throws: TransportError.self) {
                try await connection.write([UInt8](repeating: 0, count: 1 << 20))
            }
        }

        /// close() from a cancelled task still waits by the clock, not by spinning.
        @Test func closeFromACancelledTaskDoesNotSpin() async throws {
            let connection = try await shell("trap '' TERM; while :; do sleep 1; done")
            let before = cpuSeconds()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await connection.close()
            }
            await task.value
            #expect(cpuSeconds() - before < 1)
        }

        /// When whoever reads `incoming` goes away, the process is ended too.
        @Test func abandoningIncomingEndsTheProcess() async throws {
            let connection = try await connect("/bin/cat")
            let pid = connection.processIdentifier
            let reader = Task { for try await _ in connection.incoming {} }
            try await Task.sleep(for: .milliseconds(100))
            reader.cancel()
            #expect(await exits(pid, within: .seconds(5)))
        }

        /// A failure that happened before close() is still reported.
        @Test func failureBeforeCloseIsStillReported() async throws {
            // The background sleep keeps the pipes open for a moment after sh exits.
            let connection = try await shell(
                "echo 'Permission denied (publickey).' >&2; (sleep 0.5) & exit 255")
            try await Task.sleep(for: .milliseconds(200))
            await connection.close()
            let result = await drain(connection)
            #expect(result.error as? TransportError == .exited(status: 255, failure: .permissionDenied))
        }

        /// close() doesn't wait behind a write the process isn't reading.
        @Test func closeCancelsAStuckWrite() async throws {
            let connection = try await shell("sleep 1; cat > /dev/null")
            let writer = Task { try await connection.write([UInt8](repeating: 0, count: 4 << 20)) }
            try await Task.sleep(for: .milliseconds(100))
            await connection.close()
            await #expect(throws: TransportError.self) { try await writer.value }
        }

        /// A process killed by a signal is told apart from one that exited with that number.
        @Test func signalIsReportedAsNegativeStatus() async throws {
            let connection = try await shell("kill -9 $$")
            let result = await drain(connection)
            #expect(
                result.error as? TransportError
                    == .exited(status: -9, failure: .other("ssh was stopped by signal 9")))
        }

        @Test func launchFailure() async {
            let transport = ProcessTransport(executable: URL(filePath: "/nonexistent"), arguments: [])
            await #expect {
                _ = try await transport.connect()
            } throws: { error in
                if case .launchFailed = error as? TransportError { true } else { false }
            }
        }

        @Test func systemSSHUsesTheCommand() throws {
            let command = SSHCommand(target: try SSHTarget("omarchy"))
            let transport = SystemSSHTransport(command: command)
            #expect(transport.process.executable == URL(filePath: "/usr/bin/ssh"))
            #expect(transport.process.arguments == command.arguments)
        }
    }
#endif
