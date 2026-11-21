#if os(macOS)
    import GliffProtocol
    import Testing

    @testable import GliffSession

    /// The window's size through a whole session against `fake-server serve resize`, which
    /// answers each Resize as upstream's server does (a mirror fitted, never larger; a virtual
    /// screen rounded by `clean_mode`) and fails on a repeated or impossible Resize.
    extension SessionIntegrationTests {
        /// Runs `serve resize args`, setting `target` when `setOn` first comes true for a status,
        /// until frame 3 (the keyframe after the answering StreamConfig) has decoded and a
        /// further `quiet` has passed with nothing more; then disconnects.
        private func resizeSession(
            _ args: [String], target: ViewTarget,
            setOn: @escaping @Sendable (SessionStatus) -> Bool = { _ in true }
        ) async throws -> (Outcome, SpyDecoder) {
            let decoder = SpyDecoder()
            let set = Flag()
            let outcome = try await session(
                ["resize"] + args, decoder: decoder,
                drive: { session in
                    await decoder.waitFor(3)
                    try? await Task.sleep(for: .milliseconds(700))
                    await session.disconnect()
                },
                onStatus: { status, session in
                    if setOn(status), set.raise() { session.setViewTarget(target) }
                })
            return (outcome, decoder)
        }

        @Test func aMirrorIsToldTheWindowOnce() async throws {
            let target = ViewTarget(width: 1000, height: 600, backingScale: 2, textFactor: 1)
            let (outcome, decoder) = try await resizeSession(["--expect-resizes", "1"], target: target)
            #expect(outcome.serverFailure == nil)
            #expect(outcome.end == .disconnected)
            #expect(decoder.configs.map { [$0.viewWidth, $0.viewHeight] } == [[1280, 720], [1000, 562]])
        }

        @Test func aVirtualScreenGetsItsScale() async throws {
            let target = ViewTarget(width: 1600, height: 1000, backingScale: 2, textFactor: 0.75)
            let (outcome, decoder) = try await resizeSession(
                ["--headless", "--expect-resizes", "1"], target: target)
            #expect(outcome.serverFailure == nil)
            let last = try #require(decoder.configs.last)
            // clean_mode(1600, 1000, 1.5): multiples of 6.
            #expect([last.width, last.height, last.viewWidth, last.viewHeight] == [1596, 996, 1596, 996])
            #expect(last.scaleMilli == 1500)
        }

        /// A target set while connecting goes once streaming has started.
        @Test func aTargetBeforeStreamingWaits() async throws {
            let target = ViewTarget(width: 1000, height: 600, backingScale: 2, textFactor: 1)
            let (outcome, decoder) = try await resizeSession(["--expect-resizes", "1"], target: target) {
                $0 == .connecting
            }
            #expect(outcome.serverFailure == nil)
            #expect(decoder.configs.count == 2)
        }
    }
#endif
