import Foundation
import GliffProtocol
import Testing

@testable import GliffVideo

/// Real gliff-server streams decode one picture per frame, each in its own `decode` call: the
/// decoder holds no frame back, and keeps up with the stream's frame rate.
/// Pixels are never written out or printed: a recording shows someone's screen.
struct RecordedStreamTests {
    @Test(
        .disabled(
            if: RecordedStreams.all.isEmpty,
            "no recordings: record one with Debug ▸ Record 5 Seconds into .recordings/"),
        arguments: RecordedStreams.all)
    func recordingsDecodeEveryFrame(url: URL) async throws {
        let decoder = try VideoToolboxDecoder(device: MetalTestSupport.device, slot: PictureSlot())
        for segment in try GliffrecReader.read(url) {
            // A new StreamConfig sets the decoder up again: decoding starts at its keyframe.
            guard let first = segment.frames.firstIndex(where: \.header.isKeyframe) else { continue }
            try await decoder.configure(segment.config)
            var times: [Duration] = []
            for frame in segment.frames[first...] {
                let start = ContinuousClock.now
                let outcome = await decoder.decode(frame.header, main: frame.main, aux: frame.aux)
                times.append(ContinuousClock.now - start)
                #expect(
                    outcome == .picture, "\(url.lastPathComponent) frame \(frame.header.frameID): \(outcome)")
            }
            let median = times.sorted()[times.count / 2]
            let budget = Duration.seconds(1) / Int(max(segment.config.fpsCap, 1))
            #expect(median < budget, "median decode \(median), budget \(budget)")
        }
    }
}
