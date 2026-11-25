#if os(macOS)
    import Darwin
    import Foundation
    import GliffTestSupport
    import GliffTransport
    import Synchronization
    import Testing

    @testable import GliffMacros

    /// `MacroWrapper.script` itself, run by local shells through `LocalHostConnection`, whose
    /// close only closes stdin: only the wrapper can end a script, so each pid is checked before
    /// the teardown's kill.
    @Suite(.timeLimit(.minutes(1))) final class MacroWrapperShellTests: Sendable {
        static let loginShells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/csh", "/bin/tcsh"]
        /// Added to each time the wrapper's own `sleep`s set, for a machine busy with other tests.
        static let slack = Duration.seconds(2)
        /// A script's first words when it ignores TERM and HUP, and so its children do too.
        static let trapsTerm = "trap \"\" HUP TERM; "

        let folder: URL
        private let hosts = Mutex<[LocalHostConnection]>([])

        init() throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "glifftop-wrapper-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        deinit {
            for host in hosts.withLock({ $0 }) { host.killLeftovers() }
            try? FileManager.default.removeItem(at: folder)
        }

        /// A connection whose login shell is `shell`, with `HOME` in the test's folder.
        func host(shell: String = "/bin/sh", environment: [String: String] = [:]) -> LocalHostConnection {
            let host = LocalHostConnection(
                shell: shell, environment: environment.merging(["HOME": folder.path]) { old, _ in old })
            hosts.withLock { $0.append(host) }
            return host
        }

        /// A folder holding only `sh`, as `target`: a `PATH` without `head` on its own.
        func bin(sh target: String) throws -> String {
            let bin = folder.appending(path: "bin-\(UUID())")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: bin.appending(path: "sh"), withDestinationURL: URL(filePath: target))
            return bin.path
        }

        /// Starts `script` with `limit` seconds, writing its text less the last `cut` bytes, and
        /// closing stdin after a cut text.
        func run(_ script: String, limit: Int = 30, cut: Int = 0, on host: LocalHostConnection? = nil)
            async throws -> WrapperRun
        {
            let token = MacroToken.random()
            let context = try MacroContext(
                moment: .ready, reconnecting: false, screen: .focused, output: "DP-1", headless: false)
            let text = try MacroScript.text(for: script, context: context, token: token)
            let command = MacroWrapper.commandLine(length: text.count, limit: limit, token: token)
            let run = WrapperRun(
                channel: try (host ?? self.host()).localChannel(command: command), token: token)
            try? await run.channel.write(Array(text.dropLast(cut)))
            if cut > 0 { await run.channel.close() }
            return run
        }

        var pidFile: URL { folder.appending(path: "pid") }
        /// Starts `sleep 600` and writes its pid, after `setup`; then waits for it, or ends.
        func sleeper(_ setup: String = "", waits: Bool = true) -> String {
            "\(setup)sleep 600 & echo $! >| \(SSHCommand.shellQuoted(pidFile.path))" + (waits ? "; wait" : "")
        }

        @Test(arguments: loginShells) func runsUnderEachLoginShell(shell: String) async throws {
            let run = try await run("echo ran", on: host(shell: shell))
            #expect(await run.trailer(within: .seconds(10)) == "exit 0")
            #expect(run.body == "ran\n")
        }

        @Test func startLineComesFirst() async throws {
            let run = try await run("echo hello")
            #expect(await run.trailer(within: .seconds(10)) == "exit 0")
            #expect(run.output == "\(run.startLine)hello\n\n#\(run.token.hex) exit 0\n")
        }

        @Test(arguments: [0, 3, 255]) func exitStatusesAreReported(status: Int) async throws {
            let run = try await run("echo before; exit \(status)")
            #expect(await run.trailer(within: .seconds(10)) == "exit \(status)")
            #expect(run.body == "before\n")
        }

        @Test(arguments: ["cat", "read line || echo none"]) func aScriptReadingStdinEndsAtOnce(script: String)
            async throws
        {
            let run = try await run(script)
            #expect(await run.trailer(within: .seconds(3)) == "exit 0")
        }

        @Test func aBackgroundChildHoldingStdoutDoesntHoldTheRun() async throws {
            let run = try await run(sleeper(waits: false))
            #expect(await run.trailer(within: .seconds(3)) == "exit 0")
            let pid = try #require(await writtenPid(pidFile))
            #expect(await within(.seconds(1) + Self.slack) { isGone(pid) })
        }

        /// After its trailer the wrapper ends its own group, a child that traps TERM included,
        /// with no close from the Mac.
        @Test func aRunEndsItsGroupWithoutTheMac() async throws {
            let run = try await run(sleeper(Self.trapsTerm, waits: false))
            #expect(await run.trailer(within: .seconds(3)) == "exit 0")
            let pid = try #require(await writtenPid(pidFile))
            #expect(await within(.seconds(3) + Self.slack) { isGone(pid) && isGone(run.channel.pid) })
            #expect(await run.end(within: .seconds(1)) != nil)
        }

        /// A script and its children end at the limit; ones that ignore TERM, 2 s later, by KILL.
        @Test(arguments: [false, true]) func aTimeoutEndsTheScriptAndItsChildren(trapsTerm: Bool) async throws
        {
            let run = try await run(sleeper(trapsTerm ? Self.trapsTerm : ""), limit: 2)
            let pid = try #require(await writtenPid(pidFile))
            #expect(await within(.seconds(trapsTerm ? 5 : 3) + Self.slack) { isGone(pid) })
            #expect(await run.trailer(within: .seconds(1)) == "timeout")
        }

        /// Closing stdin ends a running script; one that ignores TERM, 2 s later, by KILL.
        @Test(arguments: [false, true]) func closingStdinEndsARunningScript(trapsTerm: Bool) async throws {
            let run = try await run(sleeper(trapsTerm ? Self.trapsTerm : ""))
            let pid = try #require(await writtenPid(pidFile))
            await run.channel.close()
            #expect(await within(.seconds(trapsTerm ? 3 : 1) + Self.slack) { isGone(pid) })
        }

        /// The token's line, or half of it, never arrives: nothing runs.
        @Test(arguments: [10, 34, 200]) func aShortTextRunsNothing(cut: Int) async throws {
            let marker = folder.appending(path: "marker")
            let run = try await run("touch \(SSHCommand.shellQuoted(marker.path))", cut: cut)
            #expect(await run.channel.exitStatus() == 125)
            #expect(await run.end(within: .seconds(3)) == .some(nil))
            #expect(run.output == "")
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }

        @Test func noHeadEnds126() async throws {
            let host = host(environment: ["PATH": try bin(sh: "/bin/sh")])
            let run = try await run("echo ran", on: host)
            #expect(await run.channel.exitStatus() == 126)
            #expect(run.output == "")
            await run.channel.close()
            let end = await run.end(within: .seconds(3))
            #expect((end ?? nil) != nil, "a close after the exit keeps its failure")
        }

        @Test func theScriptSeesNoWrapperState() async throws {
            let names = MacroWrapper.variables + ["glifftop_script"]
            let run = try await run(
                "printf '[%s][%s]' \"$#\" \"${1-}\"; "
                    + names.map { "printf '[%s]' \"${\($0)-u}\"; " }.joined()
                    + "command -v glifftop_end >/dev/null && printf '[end]'; echo")
            #expect(await run.trailer(within: .seconds(10)) == "exit 0")
            #expect(run.body == "[0][]" + String(repeating: "[u]", count: names.count) + "\n")
        }

        @Test func anotherTokensTrailerIsOutput() async throws {
            let other = MacroToken.random()
            let run = try await run("echo '#\(other.hex) exit 0'; echo after; exit 7")
            #expect(await run.trailer(within: .seconds(10)) == "exit 7")
            #expect(run.body == "#\(other.hex) exit 0\nafter\n")
        }

        /// With dash as `sh`. bash 5 gives the same line (checked on a host); macOS's bash 3.2
        /// counts one less, so it isn't checked here.
        @Test func errorLineNumbersMatchTheScript() async throws {
            let host = host(environment: ["PATH": try bin(sh: "/bin/dash") + ":/usr/bin:/bin"])
            let run = try await run("true\n\nglifftop_missing_command\nexit 0", on: host)
            #expect(await run.trailer(within: .seconds(10)) == "exit 0")
            #expect(run.body == "glifftop-macro: 3: eval: glifftop_missing_command: not found\n")
        }

        /// An rc file writes to stderr before the wrapper starts: neither the output nor the
        /// channel's failure carries it.
        @Test(arguments: [false, true]) func stderrBeforeTheWrapperNeverReachesTheResult(noHead: Bool)
            async throws
        {
            let marker = "glifftop-rc-marker"
            try "print -u2 \(marker)\n".write(
                to: folder.appending(path: ".zshenv"), atomically: true, encoding: .utf8)
            let path = noHead ? try bin(sh: "/bin/sh") : "/usr/bin:/bin"
            let host = host(shell: "/bin/zsh", environment: ["ZDOTDIR": folder.path, "PATH": path])
            let run = try await run("echo ran; exit 3", on: host)
            if noHead {
                let end = try #require(await run.end(within: .seconds(10)))
                let failure = try #require(end)
                #expect(run.channel.stderr.contains(marker))
                #expect(!"\(failure)".contains(marker))
            } else {
                #expect(await run.trailer(within: .seconds(10)) == "exit 3")
            }
            #expect(!run.output.contains(marker))
        }

        @Test func aStaleSignatureIsClearedWhenNoInstanceAnswers() async throws {
            let bin = try bin(sh: "/bin/sh")
            let hyprctl = URL(filePath: bin).appending(path: "hyprctl")
            try "#!/bin/sh\nexit 1\n".write(to: hyprctl, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hyprctl.path)
            let host = host(environment: [
                "HYPRLAND_INSTANCE_SIGNATURE": "stale", "PATH": bin + ":/usr/bin:/bin",
            ])
            let run = try await run("echo \"[${HYPRLAND_INSTANCE_SIGNATURE-unset}]\"", on: host)
            #expect(await run.trailer(within: .seconds(10)) == "exit 0")
            #expect(run.body == "[unset]\n")
        }
    }
#endif
