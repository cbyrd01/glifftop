#if os(macOS)
    import Foundation
    import GliffTransport
    import Synchronization
    import Testing

    @testable import GliffPorts

    /// The watcher's script run by each shell, with the real `cat`, `awk` and `sort`, stub `id`
    /// (uid 1000), `sleep` (0.2 s) and `ss` on PATH, and its proc folder a copy of `Fixtures/proc`.
    @Suite final class PortWatchScriptTests {
        let root = URL.temporaryDirectory.appending(path: "gpw-\(UUID().uuidString.prefix(8))")
        var proc: URL { root.appending(path: "proc") }
        var stubs: URL { root.appending(path: "bin") }
        static let nonce = "00112233445566ff"

        init() throws {
            let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixtures.appending(path: "proc"), to: proc)
            try stub("id", "echo 1000")
            try stub("sleep", "exec /bin/sleep 0.2")
            try stub("ss", "cat \"\(fixtures.appending(path: "ss.txt").path)\"")
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func stub(_ name: String, _ body: String) throws {
            let url = stubs.appending(path: name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        /// The script running under `shell`, its output collected.
        final class Run {
            let process = Process()
            let input = Pipe()
            private let output = Pipe()
            private let collected = Collected()

            final class Collected: Sendable {
                let bytes = Mutex<[UInt8]>([])
                let ended = Mutex(false)
            }

            init(shell: String, proc: URL, stubs: URL, environment: [String: String] = [:]) throws {
                process.executableURL = URL(filePath: shell)
                process.arguments = [
                    "-c", PortWatchCommand.script, "gliff-ports", PortWatchScriptTests.nonce, proc.path,
                ]
                process.environment = environment.merging(["PATH": stubs.path + ":/usr/bin:/bin"]) { $1 }
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                output.fileHandleForReading.readabilityHandler = { [collected] handle in
                    let data = handle.availableData
                    if data.isEmpty { collected.ended.withLock { $0 = true } }
                    collected.bytes.withLock { $0 += data }
                }
                try process.run()
            }

            var outputs: [PortListParser.Output] {
                var parser = PortListParser(nonce: PortWatchScriptTests.nonce)
                return parser.feed(collected.bytes.withLock { $0 })
            }

            /// Every writer of the output has let go: on a channel, sshd closes it.
            var outputEnded: Bool { collected.ended.withLock { $0 } }

            /// The output's lines, as bytes.
            var lines: [ArraySlice<UInt8>] {
                collected.bytes.withLock { $0 }.split(separator: UInt8(ascii: "\n"))
            }

            var frames: [PortFrame] {
                outputs.compactMap { if case .frame(let frame) = $0 { frame } else { nil } }
            }

            func closeInput() { try? input.fileHandleForWriting.close() }

            func stop() {
                if process.isRunning { process.terminate() }
                closeInput()
                output.fileHandleForReading.readabilityHandler = nil
            }
        }

        func run(_ shell: String = "/bin/sh", environment: [String: String] = [:]) throws -> Run {
            try Run(shell: shell, proc: proc, stubs: stubs, environment: environment)
        }

        /// Whether `condition` holds within `seconds`.
        func within(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }

        @Test(arguments: ["/bin/sh", "/bin/dash"]) func theShellLivesWhileStdinIsOpen(_ shell: String)
            async throws
        {
            let run = try run(shell)
            defer { run.stop() }
            try await Task.sleep(for: .seconds(3))
            #expect(run.process.isRunning)
            #expect(run.frames.count == 1)
        }

        @Test(arguments: ["/bin/sh", "/bin/dash"]) func theShellEndsWithinOneSecondOfStdinClosing(
            _ shell: String
        )
            async throws
        {
            // A sleep that outlasts the wait: it must not hold the channel's output.
            try stub("sleep", "exec /bin/sleep 5")
            let run = try run(shell)
            defer { run.stop() }
            #expect(await within(5) { run.frames.count == 1 })
            run.closeInput()
            #expect(await within(1) { !run.process.isRunning && run.outputEnded })
        }

        @Test(arguments: ["/bin/sh", "/bin/dash"]) func aChangePrintsOneFrame(_ shell: String) async throws {
            let run = try run(shell)
            defer { run.stop() }
            #expect(await within(5) { run.frames.count == 1 })
            let tcp = proc.appending(path: "net/tcp")
            let added =
                "   3: 0100007F:2328 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 20009 1 0000000000000000 100 0 0 10 0\n"
            try (String(contentsOf: tcp, encoding: .utf8) + added).write(
                to: tcp, atomically: true, encoding: .utf8)
            #expect(await within(5) { run.frames.count == 2 })
            try await Task.sleep(for: .seconds(1))
            #expect(run.frames.count == 2)
            #expect(run.frames.last?.sockets.contains { $0.port == 9000 } == true)
        }

        @Test func theFirstFrameListsThePersonsSockets() async throws {
            let run = try run()
            defer { run.stop() }
            #expect(await within(5) { run.frames.count == 1 })
            let frame = try #require(run.frames.first)
            #expect(frame.uid == 1000)
            #expect(frame.ephemeral == 32768...60999)
            #expect(
                frame.sockets.map { "\($0.address.text) \($0.port) \($0.name ?? "-")" } == [
                    ":: 8080 python3", "::1 631 cupsd", "127.0.0.1 5173 node",
                ])
        }

        @Test func noChangePrintsNothing() async throws {
            let run = try run()
            defer { run.stop() }
            #expect(await within(5) { run.frames.count == 1 })
            try await Task.sleep(for: .seconds(1))
            #expect(run.frames.count == 1)
        }

        /// `ss`'s queue columns change on every call: no frame follows the first.
        @Test func aQueueOnlyChangePrintsNothing() async throws {
            let count = root.appending(path: "count")
            try stub(
                "ss",
                "n=$(cat \"\(count.path)\" 2>/dev/null || echo 0); echo $((n + 1)) > \"\(count.path)\"; "
                    + "echo \"LISTEN $n 511 127.0.0.1:5173 0.0.0.0:* users:((\\\"node\\\",pid=4242,fd=21))\"")
            let run = try run()
            defer { run.stop() }
            #expect(await within(5) { run.frames.count == 1 })
            try await Task.sleep(for: .seconds(1))
            #expect(run.frames.count == 1)
            #expect(run.frames.first?.sockets.first { $0.port == 5173 }?.name == "node")
        }

        /// Sockets shared by many processes make long `ss` lines: the frame still fits its cap.
        @Test func longSSLinesStillMakeAFrame() async throws {
            try stub(
                "ss",
                "u=; i=0; while [ $i -lt 64 ]; do u=\"$u(\\\"node\\\",pid=$i,fd=3),\"; i=$((i + 1)); done; "
                    + "n=0; while [ $n -lt 200 ]; do "
                    + "echo \"LISTEN 0 511 127.0.0.1:$((20000 + n)) 0.0.0.0:* users:($u(\\\"x\\\",pid=1,fd=3))\"; "
                    + "n=$((n + 1)); done; "
                    + "echo \"LISTEN 0 511 127.0.0.1:5173 0.0.0.0:* users:($u(\\\"x\\\",pid=1,fd=3))\"")
            let run = try run()
            defer { run.stop() }
            #expect(await within(5) { run.frames.count == 1 })
            #expect(!run.outputs.contains(.overflow))
            #expect(run.frames.first?.sockets.first { $0.port == 5173 }?.name == "node")
        }

        /// A name line is cut by bytes, whatever the host's locale.
        @Test func aMultibyteNameLineIsCutByBytes() async throws {
            let wide = String(repeating: "\u{00E9}", count: 200)
            try stub(
                "ss", "echo \"LISTEN 0 511 127.0.0.1:5173 0.0.0.0:* users:((\\\"\(wide)\\\",pid=1,fd=3))\"")
            let run = try run(environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"])
            defer { run.stop() }
            #expect(await within(5) { run.frames.count == 1 })
            let named = run.lines.filter { $0.starts(with: Array("N ".utf8)) }
            #expect(named.count == 1)
            #expect((named.first?.count ?? .max) <= 2 + PortWatchCommand.maxNameLine)
        }

        /// Other users' sockets (no `users:` field) don't count toward the cap on names.
        @Test func unnamedSSLinesLeaveRoomForNamedOnes() async throws {
            try stub(
                "ss",
                "n=0; while [ $n -lt 300 ]; do echo \"LISTEN 0 511 127.0.0.1:$((20000 + n)) 0.0.0.0:*\"; "
                    + "n=$((n + 1)); done; "
                    + "echo \"LISTEN 0 511 127.0.0.1:5173 0.0.0.0:* users:((\\\"node\\\",pid=1,fd=3))\"")
            let run = try run()
            defer { run.stop() }
            #expect(await within(5) { run.frames.count == 1 })
            #expect(run.frames.first?.sockets.first { $0.port == 5173 }?.name == "node")
        }

        @Test func withoutProcItPrintsNoneAndExits() async throws {
            try FileManager.default.removeItem(at: proc.appending(path: "net"))
            let run = try run()
            defer { run.stop() }
            #expect(await within(2) { !run.process.isRunning })
            #expect(run.outputs == [.unavailable])
        }

        @Test func withoutSSItStillPrintsTheRows() async throws {
            try FileManager.default.removeItem(at: stubs.appending(path: "ss"))
            let run = try run()
            defer { run.stop() }
            #expect(await within(5) { run.frames.count == 1 })
            #expect(run.frames.first?.sockets.count == 3)
            #expect(run.frames.first?.sockets.allSatisfy { $0.name == nil } == true)
        }

        @Test(arguments: [PortWatchScriptTests.nonce, "x;y $z"]) func theCommandRunsThroughShellQuoting(
            _ nonce: String
        ) async throws {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", PortWatchCommand.make(nonce: nonce, proc: root.path + "/none")]
            process.environment = ["PATH": stubs.path + ":/usr/bin:/bin"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(text == "B \(nonce) none\nE \(nonce)\n")
        }

        @Test func theScriptHasNoSingleQuoteOrBangOrNewline() {
            #expect(!PortWatchCommand.script.contains { $0 == "'" || $0 == "!" || $0.isNewline })
        }

        @Test func aNonceIsSixteenLowercaseHex() {
            let nonce = PortWatchCommand.nonce()
            #expect(nonce.count == 16)
            #expect(nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(nonce != PortWatchCommand.nonce())
        }
    }
#endif
