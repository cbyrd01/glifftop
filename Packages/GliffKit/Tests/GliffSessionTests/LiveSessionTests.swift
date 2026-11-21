#if os(macOS)
    import Foundation
    import GliffSession
    import GliffTransport
    import GliffVideo
    import Metal
    import Testing

    /// Where and how long `LiveSessionTests` streams, from the environment.
    enum LiveHost {
        static let target = ProcessInfo.processInfo.environment["GLIFFTOP_LIVE_HOST"]
        static let seconds =
            ProcessInfo.processInfo.environment["GLIFFTOP_LIVE_SECONDS"].flatMap(Int.init) ?? 120
    }

    /// A real session against a real gliff-server, headless: the remote check for when the app's
    /// window can't be watched. Off unless `GLIFFTOP_LIVE_HOST` names an ssh destination
    /// (`GLIFFTOP_LIVE_SECONDS`, 1–540, default 120, sets how long it streams). It watches the
    /// screen, and starts one headless session (a virtual screen the server removes at its end)
    /// that it resizes. One test at a time, so the sessions don't share the host's GPU. Only
    /// numbers are reported, never pixels, as attachments (`swift test --attachments-path DIR`).
    @Suite(
        .enabled(if: LiveHost.target != nil, "set GLIFFTOP_LIVE_HOST to run against a real server"),
        .serialized,
        .timeLimit(.minutes(10)))
    struct LiveSessionTests {
        @Test func streamsDecodesAndAcksForTheWholeRun() async throws {
            let target = try SSHTarget(try #require(LiveHost.target))
            try #require((1...540).contains(LiveHost.seconds), "GLIFFTOP_LIVE_SECONDS must be 1–540")
            let slot = PictureSlot()
            let decoder = try VideoToolboxDecoder(
                device: try #require(MTLCreateSystemDefaultDevice()), slot: slot)
            let session = Session(
                transport: SystemSSHTransport(command: SSHCommand(target: target)),
                configuration: SessionConfiguration(maxWidth: 2560, maxHeight: 1440), decoder: decoder)
            let runner = Task { await session.run() }
            // Timed from the first StreamConfig (`.streaming`), not from ssh: connecting may wait
            // on an ssh-agent approval.
            var stopper: Task<Void, Never>?
            var stream: StreamInfo?
            var stats: [SessionStats] = []
            var end: SessionEnd?
            for await status in session.status {
                switch status {
                case .streaming(let info):
                    stream = info
                    if stopper == nil {
                        stopper = Task {
                            try? await Task.sleep(for: .seconds(LiveHost.seconds))
                            await session.disconnect()
                        }
                    }
                case .stats(let report): stats.append(report)
                case .ended(let reason): end = reason
                default: break
                }
            }
            // Disconnect whatever ended the loop (a cancelled test too), so ssh never outlives it.
            stopper?.cancel()
            await session.disconnect()
            await runner.value

            #expect(end == .disconnected, "the session ended early: \(String(describing: end))")
            let info = try #require(stream)
            Attachment.record(
                Self.summary(info, stats, pictures: slot.latest?.generation ?? 0), named: "live-summary.txt")
            #expect(slot.latest != nil, "no picture was decoded")
            // The session's tick kept reporting about once a second to the end. (Whether pictures
            // kept coming is in the summary: a static screen legitimately sends none.)
            let expected = Int(Double(LiveHost.seconds) * 0.9)
            #expect(stats.count >= expected, "\(stats.count) stats reports in \(LiveHost.seconds) s")
        }

        /// On a real server: a virtual screen takes the window's size, then a smaller
        /// text size (a scale of 1.5 on a 2× display). Headless sessions on the test host are fine.
        @Test func aVirtualScreenFollowsAResize() async throws {
            let target = try SSHTarget(try #require(LiveHost.target))
            let command = SSHCommand(target: target, serverArguments: ScreenChoice.virtual.serverArguments)
            let session = Session(
                transport: SystemSSHTransport(command: command),
                configuration: SessionConfiguration(maxWidth: 2560, maxHeight: 1440),
                decoder: NullFrameDecoder())
            let runner = Task { await session.run() }
            // Each step waits for the server's answer; a minute in all, from the first StreamConfig.
            var deadline: Task<Void, Never>?
            var step = 0
            var streams: [StreamInfo] = []
            var end: SessionEnd?
            func window(factor: Double) -> ViewTarget {
                ViewTarget(width: 1600, height: 1000, backingScale: 2, textFactor: factor)
            }
            for await status in session.status {
                switch status {
                case .streaming(let info):
                    streams.append(info)
                    if deadline == nil {
                        deadline = Task {
                            try? await Task.sleep(for: .seconds(60))
                            await session.disconnect()
                        }
                    }
                    let sized = info.viewWidth == 1600 && info.viewHeight == 1000
                    if step == 0 {
                        step = 1
                        session.setViewTarget(window(factor: 1))
                    }
                    // A screen already at the target gets no answer, so this is checked at once.
                    if step == 1, sized, abs(info.screenScale - 2) < 0.01 {
                        step = 2
                        session.setViewTarget(window(factor: 0.75))
                    } else if step == 2, abs(info.screenScale - 1.5) < 0.01 {
                        step = 3
                        await session.disconnect()
                    }
                case .ended(let reason): end = reason
                default: break
                }
            }
            deadline?.cancel()
            await session.disconnect()
            await runner.value

            let seen = streams.map {
                "\($0.width)×\($0.height) view \($0.viewWidth)×\($0.viewHeight) scale \($0.scaleMilli)"
            }
            Attachment.record("live: " + seen.joined(separator: "\nlive: "), named: "live-virtual.txt")
            #expect(step == 3, "stopped at step \(step): \(seen)")
            #expect(end == .disconnected, "the session ended early: \(String(describing: end))")
        }

        private static func summary(_ info: StreamInfo, _ stats: [SessionStats], pictures: UInt64) -> String {
            func spread(_ values: [Double]) -> String {
                guard !values.isEmpty else { return "none" }
                let sorted = values.sorted()
                let median = sorted[sorted.count / 2]
                return String(
                    format: "min %.1f, median %.1f, max %.1f", sorted[0], median, sorted[sorted.count - 1])
            }
            let shown = stats.filter { $0.framesPerSecond > 0 }
            return """
                live: \(info.chroma) \(info.pipeline.map { "\($0)" } ?? "?") stream \(info.width)×\(info.height) \
                view \(info.viewWidth)×\(info.viewHeight) cap \(info.fpsCap) fps
                live: \(pictures) pictures, \(stats.count) stats reports, \(shown.count) with pictures
                live: fps \(spread(stats.map(\.framesPerSecond)))
                live: decode ms (seconds with pictures) \(spread(shown.map(\.decodeMilliseconds)))
                live: Mbit/s \(spread(stats.map(\.megabitsPerSecond)))
                live: RTT ms \(spread(stats.compactMap(\.roundTripMilliseconds)))
                """
        }
    }
#endif
