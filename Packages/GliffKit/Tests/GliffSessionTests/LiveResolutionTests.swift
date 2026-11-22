#if os(macOS)
    import GliffProtocol
    import GliffSession
    import GliffTransport
    import GliffVideo
    import Testing

    /// A virtual screen's Resolution on a real gliff-server, headless (`LiveHost`): Standard asks
    /// for half the window's pixels a side at half the scale, and Automatic does so on the CPU
    /// pipeline (`--video cpu`). Off unless `GLIFFTOP_LIVE_HOST` is set; numbers only.
    @Suite(
        .enabled(if: LiveHost.target != nil, "set GLIFFTOP_LIVE_HOST to run against a real server"),
        .serialized,
        .timeLimit(.minutes(3)))
    struct LiveResolutionTests {
        /// A 1600×1000 window at 2×, Standard: the host draws 800×500 at a scale of 1.
        @Test func aStandardVirtualScreenDrawsAQuarter() async throws {
            let seen = try await Self.virtualScreen(serverArguments: ["--headless"], resolution: .standard)
            Attachment.record("live: " + seen.description, named: "live-standard.txt")
            #expect(seen.reached, "\(seen), ended \(String(describing: seen.end))")
        }

        /// The same window at Automatic, on the CPU pipeline: Standard's picture.
        @Test func automaticChoosesStandardOnTheCPU() async throws {
            let seen = try await Self.virtualScreen(
                serverArguments: ["--headless", "--video", "cpu"], resolution: .automatic)
            Attachment.record("live: " + seen.description, named: "live-automatic-cpu.txt")
            #expect(seen.pipelines.allSatisfy { $0 == .cpu }, "\(seen)")
            #expect(seen.reached, "\(seen), ended \(String(describing: seen.end))")
        }

        struct Seen: CustomStringConvertible {
            var streams: [String] = []
            var pipelines: [VideoPipeline?] = []
            var reached = false
            var end: SessionEnd?
            /// The numbers only, for the attachment.
            var description: String { "\(streams)" }
        }

        /// Starts a virtual screen, sets a 1600×1000 window at 2× at `resolution`, and waits up
        /// to a minute for an 800×500 view at a scale of 1.
        private static func virtualScreen(serverArguments: [String], resolution: VirtualResolution)
            async throws -> Seen
        {
            let target = try SSHTarget(try #require(LiveHost.target))
            let session = Session(
                transport: SystemSSHTransport(
                    command: SSHCommand(target: target, serverArguments: serverArguments)),
                configuration: SessionConfiguration(maxWidth: 2560, maxHeight: 1440),
                decoder: NullFrameDecoder())
            let runner = Task { await session.run() }
            var deadline: Task<Void, Never>?
            var seen = Seen()
            for await status in session.status {
                switch status {
                case .streaming(let info):
                    seen.streams.append("\(info.viewWidth)×\(info.viewHeight) scale \(info.scaleMilli)")
                    seen.pipelines.append(info.pipeline)
                    if deadline == nil {
                        session.setViewTarget(
                            ViewTarget(
                                width: 1600, height: 1000, backingScale: 2, textFactor: 1,
                                resolution: resolution))
                        deadline = Task {
                            try? await Task.sleep(for: .seconds(60))
                            await session.disconnect()
                        }
                    }
                    if info.viewWidth == 800, info.viewHeight == 500, abs(info.screenScale - 1) < 0.01 {
                        seen.reached = true
                        await session.disconnect()
                    }
                case .ended(let reason): seen.end = reason
                default: break
                }
            }
            deadline?.cancel()
            await session.disconnect()
            await runner.value
            return seen
        }
    }
#endif
