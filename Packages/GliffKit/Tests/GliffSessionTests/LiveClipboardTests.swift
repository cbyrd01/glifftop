#if os(macOS)
    import Foundation
    import GliffClipboard
    import GliffInput
    import GliffTransport
    import GliffVideo
    import Testing

    import GliffSession

    /// Serves each offer's string (by its token) for any type.
    private struct LiveSource: LocalClipboardSource {
        let texts: [Int: [UInt8]]

        func source(for mime: String, token: Int) async throws(TransferError) -> any ChunkSource {
            guard let text = texts[token] else { throw .replaced }
            return MemorySource(text)
        }
    }

    /// Clipboard sharing on a real host: an ordinary Mac copy and a password manager's,
    /// each pasted on the host. Off unless `GLIFFTOP_LIVE_HOST` is set. It sets the host's
    /// clipboard to two test strings; the ordinary one stays in the host's
    /// clipboard history, which shows the history check can see it. Only numbers are reported,
    /// as `live-clipboard.txt`.
    @Suite(
        .enabled(if: LiveHost.target != nil, "set GLIFFTOP_LIVE_HOST to run against a real server"),
        .serialized,
        .timeLimit(.minutes(3)))
    struct LiveClipboardTests {
        /// Both paste on the host at once, with no input; the history keeps the ordinary copy
        /// and not the password.
        @Test func aMacCopyPastesOnTheHost() async throws {
            let ordinary = Self.marker()
            let password = Self.marker()
            let live = try await LiveClipboardSession.start(texts: [
                1: Array(ordinary.utf8), 2: Array(password.utf8),
            ])
            // The session always ends, whatever the probe throws, so ssh never outlives the test.
            let probed: Result<[Probe], any Error>
            do {
                probed = .success([
                    try await Self.probe(live, marker: ordinary, token: 1, isPassword: false),
                    try await Self.probe(live, marker: password, token: 2, isPassword: true),
                ])
            } catch {
                probed = .failure(error)
            }
            let ending = await live.end()
            let probes = try probed.get()

            Attachment.record(
                """
                live: ordinary: types \(probes[0].types), pasted bytes \(probes[0].pastedBytes), \
                matched \(probes[0].matched ? 1 : 0), history hits \(probes[0].hits)
                live: password: types \(probes[1].types), pasted bytes \(probes[1].pastedBytes), \
                matched \(probes[1].matched ? 1 : 0), history hits \(probes[1].hits)
                live: interruptions \(ending.interruptions), ended as asked \(ending.end == .disconnected ? 1 : 0)
                """,
                named: "live-clipboard.txt")
            #expect(ending.end == .disconnected, "the session ended early")
            #expect(ending.interruptions == 0, "the session was interrupted")
            #expect(probes[0].matched, "the host's paste didn't get the ordinary string")
            #expect(probes[1].matched, "the host's paste didn't get the password string")
            #expect(probes[0].hits >= 1, "the host's clipboard history didn't keep the ordinary copy")
            #expect(
                probes[1].hits == 0, "the password is in the host's clipboard history, or it couldn't be read"
            )
        }

        private struct Probe {
            var types = -1
            var pasted: String?
            var matched = false
            var hits = -1
            var pastedBytes: Int { pasted.map { $0.utf8.count } ?? -1 }
        }

        private static func marker() -> String {
            "glifftop-live-" + String(format: "%08x", UInt32.random(in: .min ... .max))
        }

        private static func probe(
            _ live: LiveClipboardSession, marker: String, token: Int, isPassword: Bool
        ) async throws -> Probe {
            var probe = Probe()
            live.session.offerClipboard(
                LocalClipboardOffer(
                    mimeTypes: ClipboardMimes.forwardable([ClipboardMimes.text]), token: token,
                    isPassword: isPassword))
            // The host takes it within a moment; its history, a moment more. Until it shows there:
            // up to 15 s for the ordinary copy, which must; 5 s for the password, which mustn't.
            let deadline = ContinuousClock.now + .seconds(isPassword ? 5 : 15)
            repeat {
                try await Task.sleep(for: .seconds(1))
                probe.hits = try await Remote.count(live.target, Remote.historyFiles(marker))
            } while probe.hits < 1 && ContinuousClock.now < deadline
            probe.types = try await Remote.count(live.target, Remote.env + "timeout 10 wl-paste --list-types")
            let paste = try await Remote.run(live.target, Remote.paste)
            probe.pasted = paste.status == 0 ? paste.output : nil
            probe.matched = probe.pasted == marker
            return probe
        }
    }

    /// A headless session sharing a clipboard, streaming, and how it went.
    private struct LiveClipboardSession {
        struct Ending {
            var end: SessionEnd?
            var interruptions = 0
        }

        let target: String
        let session: Session
        let runner: Task<Void, Never>
        let watch: Task<Ending, Never>

        static func start(texts: [Int: [UInt8]]) async throws -> LiveClipboardSession {
            let target = try #require(LiveHost.target)
            let command = SSHCommand(
                target: try SSHTarget(target), serverArguments: ScreenChoice.virtual.serverArguments)
            let session = Session(
                transport: SystemSSHTransport(command: command),
                configuration: SessionConfiguration(maxWidth: 1920, maxHeight: 1080),
                decoder: NullFrameDecoder(),
                clipboard: ClipboardSetup(source: LiveSource(texts: texts)))
            try #require(session.clipboard != nil)
            let runner = Task { await session.run() }
            let (streaming, signal) = AsyncStream.makeStream(of: Void.self)
            let watch = Task {
                var ending = Ending()
                for await status in session.status {
                    switch status {
                    case .streaming: signal.yield()
                    case .interrupted(true): ending.interruptions += 1
                    case .ended(let reason): ending.end = reason
                    default: break
                    }
                }
                signal.finish()
                return ending
            }
            let live = LiveClipboardSession(
                target: target, session: session, runner: runner, watch: watch)
            var started = false
            for await _ in streaming {
                started = true
                break
            }
            if !started { _ = await live.end() }
            try #require(started, "the session never streamed")
            return live
        }

        func end() async -> Ending {
            await session.disconnect()
            await runner.value
            return await watch.value
        }
    }

    /// Read-only commands on the host, over their own ssh, each with a time limit there.
    private enum Remote {
        /// The host's Wayland session, found without changing anything.
        static let env =
            "export XDG_RUNTIME_DIR=/run/user/$(id -u); "
            + "export WAYLAND_DISPLAY=$(ls \"$XDG_RUNTIME_DIR\" | grep -m1 -E '^wayland-[0-9]+$'); "
        /// The host's clipboard as text, read the way a paste there reads it.
        static let paste = env + "timeout 10 wl-paste --no-newline --type text/plain"

        /// The files of the host's Omarchy state that hold `marker` (a fixed test string); fails
        /// if that directory is missing or the search can't finish.
        static func historyFiles(_ marker: String) -> String {
            "test -d ~/.local/state/omarchy || exit 3; "
                + "timeout 20 grep -rlF -- '\(marker)' ~/.local/state/omarchy 2>/dev/null; [ $? -le 1 ]"
        }

        /// The number of lines `script` prints, or -1 if it failed.
        static func count(_ target: String, _ script: String) async throws -> Int {
            let result = try await run(target, script)
            guard result.status == 0 else { return -1 }
            return result.output.split(whereSeparator: \.isNewline).count
        }

        /// Runs `script` on `target`; ended at once if the test is cancelled, and by ssh itself if
        /// the link goes quiet.
        static func run(_ target: String, _ script: String) async throws -> (output: String, status: Int32) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/ssh")
            process.arguments = [
                "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=2", "--", target, script,
            ]
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let status = await withTaskCancellationHandler {
                await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
                    process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
                    do {
                        try process.run()
                    } catch {
                        process.terminationHandler = nil
                        done.resume(returning: -1)
                    }
                }
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
            try Task.checkCancellation()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            return (String(decoding: data, as: UTF8.self), status)
        }
    }
#endif
