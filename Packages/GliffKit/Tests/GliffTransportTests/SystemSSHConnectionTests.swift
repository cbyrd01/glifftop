#if os(macOS)
    import Foundation
    import Testing

    @testable import GliffTransport

    /// `SystemSSHConnection` against a stub `ssh`: a shell script that plays the master (a file
    /// at the socket path holding its pid, removed when it ends), `-O check`, `-O exit`, and
    /// channels that echo their stdin while the master lives.
    @Suite final class SystemSSHConnectionTests {
        let root = URL(filePath: "/tmp/ssc-\(UUID().uuidString.prefix(8))")
        var socket: String { root.path + "/1-1" }

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        static let stub = #"""
            #!/bin/sh
            sock=""; request=""; master=no; prev=""
            for arg in "$@"; do
              case "$prev" in -S) sock="$arg" ;; -O) request="$arg" ;; esac
              [ "$arg" = "ControlMaster=yes" ] && master=yes
              prev="$arg"
            done
            if [ "$master" = yes ]; then
              echo $$ > "${sock%/*}/master.pid"
              [ -n "$STUB_REFUSE" ] && { echo "user@omarchy: Permission denied (publickey)." >&2; exit 255; }
              sleep "${STUB_DELAY:-0}"
              trap 'rm -f "$sock"; exit ${STUB_EXIT_STATUS:-0}' USR1
              trap 'rm -f "$sock"; echo "Timeout, server omarchy not responding." >&2; exit 255' TERM
              echo $$ > "$sock"
              while :; do sleep 0.05; done
            fi
            if [ "$request" = check ]; then [ -f "$sock" ] && exit 0; exit 255; fi
            if [ "$request" = exit ]; then
              master=$(cat "$sock"); kill -USR1 "$master"
              while kill -0 "$master" 2>/dev/null; do sleep 0.02; done
              exit 0
            fi
            [ -f "$sock" ] || { echo "kex_exchange_identification: Connection closed by remote host" >&2; exit 255; }
            pid=$(cat "$sock")
            exec 3<&0
            cat <&3 &
            echo=$!
            while kill -0 "$pid" 2>/dev/null && kill -0 "$echo" 2>/dev/null; do sleep 0.05; done
            kill -0 "$echo" 2>/dev/null || exit 0
            kill "$echo"
            echo "mux_client_read_packet: read header failed: Broken pipe" >&2
            exit 255
            """#

        func stub(_ environment: String = "") throws -> URL {
            let url = root.appending(path: "ssh")
            let script = Self.stub.replacing("#!/bin/sh\n", with: "#!/bin/sh\n\(environment)\n")
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }

        func open(_ environment: String = "") async throws -> SystemSSHConnection {
            try await SystemSSHConnection.open(
                command: SSHMasterCommand(target: SSHTarget("omarchy"), socket: socket),
                executable: stub(environment))
        }

        @Test func openWaitsForTheCheck() async throws {
            let connection = try await open("STUB_DELAY=0.3")
            #expect(FileManager.default.fileExists(atPath: socket))
            await connection.close()
        }

        @Test func aMasterThatExitsFailsTheOpen() async throws {
            await #expect(throws: TransportError.exited(status: 255, failure: .permissionDenied)) {
                try await self.open("STUB_REFUSE=1")
            }
        }

        @Test func aChannelSpeaksThroughIt() async throws {
            let connection = try await open()
            let channel = try await connection.channel(command: "gliff-server --stdio")
            try await channel.write(Array("hello\n".utf8))
            var chunks = channel.incoming.makeAsyncIterator()
            #expect(try await chunks.next() == Array("hello\n".utf8))
            await channel.close()
            await connection.close()
        }

        @Test func masterExitEndsItsChannels() async throws {
            let connection = try await open()
            let channel = try await connection.channel(command: "gliff-server --stdio")
            kill(try masterPID(), SIGTERM)
            #expect(await connection.ended() == .unreachable)
            let started = ContinuousClock.now
            await #expect(throws: TransportError.exited(status: 255, failure: .sharedConnectionLost)) {
                for try await _ in channel.incoming {}
            }
            #expect(ContinuousClock.now - started < .seconds(2))
            await #expect(throws: TransportError.exited(status: 255, failure: .sharedConnectionLost)) {
                try await connection.channel(command: "late")
            }
        }

        @Test func closeRemovesTheSocket() async throws {
            let connection = try await open()
            await connection.close()
            #expect(await connection.ended() == nil)
            #expect(!FileManager.default.fileExists(atPath: socket))
        }

        /// The master's pid, which the stub writes beside the socket.
        func masterPID() throws -> Int32 {
            let text = try String(contentsOf: root.appending(path: "master.pid"), encoding: .utf8)
            return try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        @Test func aMasterEndingByItselfIsALoss() async throws {
            let connection = try await open()
            kill(try masterPID(), SIGUSR1)
            #expect(await connection.ended() == .sharedConnectionLost)
        }

        @Test func aKilledMasterLeavesNoSocket() async throws {
            let connection = try await open()
            kill(try masterPID(), SIGKILL)
            #expect(await connection.ended() != nil)
            #expect(await eventually { !FileManager.default.fileExists(atPath: self.socket) })
        }

        @Test func aSignInThatNeverFinishesTimesOut() async throws {
            let command = try SSHMasterCommand(target: SSHTarget("omarchy"), socket: socket)
            let executable = try stub("STUB_DELAY=5")
            await #expect(throws: TransportError.exited(status: 255, failure: .signInTimedOut)) {
                try await SystemSSHConnection.open(
                    command: command, executable: executable, limit: .milliseconds(500))
            }
            #expect(kill(try masterPID(), 0) != 0)
        }

        @Test func aCloseIsNeverALoss() async throws {
            let connection = try await open("STUB_EXIT_STATUS=255")
            await connection.close()
            #expect(await connection.ended() == nil)
        }

        @Test func invalidateEndsItAsUnreachable() async throws {
            let connection = try await open()
            await connection.invalidate()
            #expect(await connection.ended() == .unreachable)
            #expect(!FileManager.default.fileExists(atPath: socket))
        }

        @Test func cancelledWhileOpeningEndsTheMaster() async throws {
            let executable = try stub("STUB_DELAY=5")
            let command = try SSHMasterCommand(target: SSHTarget("omarchy"), socket: socket)
            let opening = Task {
                try await SystemSSHConnection.open(command: command, executable: executable)
            }
            try await Task.sleep(for: .milliseconds(300))
            opening.cancel()
            let cancelled = ContinuousClock.now
            await #expect(throws: TransportError.cancelled) { try await opening.value }
            #expect(ContinuousClock.now - cancelled < .seconds(1))
            #expect(kill(try masterPID(), 0) != 0)
        }
    }
#endif
