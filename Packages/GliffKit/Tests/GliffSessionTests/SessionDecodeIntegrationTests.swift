#if os(macOS)
    import Foundation
    import GliffProtocol
    import GliffVideo
    import Metal
    import Testing

    @testable import GliffSession

    /// Real H.264 end to end: the fake server replays encode-fixtures' streams, and a session
    /// with the VideoToolbox decoder shows every frame and acks each one.
    extension SessionIntegrationTests {
        /// The synthetic streams live in GliffVideoTests' fixtures, out of this bundle's reach.
        static let gradientStreams = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(
                path: "GliffVideoTests/Fixtures/synthetic/streams/gradient-192x108")

        @Test(arguments: ["dual", "single"])
        func realStreamDecodesEveryFrame(chroma: String) async throws {
            let slot = PictureSlot()
            let device = try #require(MTLCreateSystemDefaultDevice())
            let decoder = try VideoToolboxDecoder(device: device, slot: slot)
            let args = [
                "stream", "--chroma", chroma, "--streams", Self.gradientStreams.path(percentEncoded: false),
                "--size", "192x108", "--expect-bye",
            ]
            // Stats come once a second. The window that counts the last frame reports after the
            // 8th picture is published, so wait for a report with pictures in it and all 8 shown.
            // A few reports without that end the session anyway, and the checks below fail.
            var reports = 0
            let outcome = try await session(
                args, decoder: decoder,
                onStatus: { status, session in
                    guard case .stats(let stats) = status else { return }
                    reports += 1
                    let done = stats.framesPerSecond > 0 && slot.latest?.generation == 8
                    if done || reports >= 5 { await session.disconnect() }
                })
            #expect(outcome.end == .disconnected)
            #expect(outcome.serverFailure == nil)
            #expect(slot.latest?.generation == 8)
            let stats = outcome.statuses.compactMap { status -> SessionStats? in
                if case .stats(let stats) = status { stats } else { nil }
            }
            #expect(stats.contains { $0.framesPerSecond > 0 })
        }
    }
#endif
