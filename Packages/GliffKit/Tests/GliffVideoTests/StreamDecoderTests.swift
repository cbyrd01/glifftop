import CoreMedia
import CoreVideo
import Testing

@testable import GliffVideo

struct StreamDecoderTests {
    static let bars = Result { try SyntheticFixtures.stream("bars-192x108", plane: .main) }
    static let large = Result { try SyntheticFixtures.stream("gradient-256x144", plane: .main) }

    /// Every access unit gives its picture during its own call: nothing is held back.
    @Test func onePicturePerAccessUnit() throws {
        let decoder = StreamDecoder()
        for unit in try Self.bars.get() {
            let buffer = try decoder.decode(unit[...])
            #expect(
                CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            #expect(CVPixelBufferGetWidth(buffer) >= 192)
            #expect(CVPixelBufferGetHeight(buffer) >= 108)
        }
    }

    /// More NAL units than any real picture has is a broken stream: it resets, so the next
    /// P frame waits for a keyframe instead of decoding against broken references.
    @Test func tooManyUnitsFailsAndResets() throws {
        let units = try Self.bars.get()
        let decoder = StreamDecoder()
        _ = try decoder.decode(units[0][...])
        let hostile = Array([[UInt8]](repeating: [0, 0, 1, 0x41, 0x9A], count: AnnexB.maxUnits + 1).joined())
        #expect(throws: StreamDecodeFailure.tooManyUnits) { try decoder.decode(hostile[...]) }
        #expect(throws: StreamDecodeFailure.awaitingKeyframe) { try decoder.decode(units[1][...]) }
    }

    /// A picture VideoToolbox keeps past its call gives no picture but breaks nothing: a reset
    /// (and its keyframe request) would come round on every keyframe of a stream VideoToolbox
    /// always holds, a keyframe storm. The decoder logs it instead.
    @Test func aHeldPictureIsQuiet() {
        #expect(StreamDecodeFailure.held.isNoPicture)
        #expect(!StreamDecodeFailure.held.resetsTheStream)
    }

    @Test func pFrameBeforeKeyframeAwaitsKeyframe() throws {
        let units = try Self.bars.get()
        let decoder = StreamDecoder()
        #expect(throws: StreamDecodeFailure.awaitingKeyframe) { try decoder.decode(units[1][...]) }
        #expect(throws: Never.self) { try decoder.decode(units[0][...]) }
    }

    @Test func parameterSetChangeRebuilds() throws {
        let decoder = StreamDecoder()
        for unit in try Self.bars.get().prefix(3) { _ = try decoder.decode(unit[...]) }
        let buffer = try decoder.decode(try Self.large.get()[0][...])
        #expect(CVPixelBufferGetWidth(buffer) >= 256)
        #expect(CVPixelBufferGetHeight(buffer) >= 144)
    }

    @Test func invalidatedSessionRecoversOnKeyframe() throws {
        let units = try Self.bars.get()
        let decoder = StreamDecoder()
        for unit in units.prefix(3) { _ = try decoder.decode(unit[...]) }
        decoder.invalidate()
        #expect(throws: StreamDecodeFailure.awaitingKeyframe) { try decoder.decode(units[3][...]) }
        #expect(throws: Never.self) { try decoder.decode(units[0][...]) }
    }

    /// A corrupt slice never crashes. Hardware may conceal it or reject it; if it's rejected,
    /// the decoder resets and waits for the next keyframe, which recovers.
    @Test func garbageFailsOrIsConcealed() throws {
        let units = try Self.bars.get()
        let decoder = StreamDecoder()
        _ = try decoder.decode(units[0][...])
        let garbage: [UInt8] = [0, 0, 0, 1, 0x41] + Array(repeating: 0x5A, count: 4096)
        if (try? decoder.decode(garbage[...])) == nil {
            #expect(throws: StreamDecodeFailure.awaitingKeyframe) { try decoder.decode(units[1][...]) }
        }
        #expect(throws: Never.self) { try decoder.decode(units[0][...]) }
    }

    /// Parameter sets start (or change) a stream only together with an IDR slice.
    @Test func parameterSetsWithoutAnIDRDontStart() throws {
        let units = try Self.bars.get()
        let withP = Self.parameterSetsOnly(units[0]) + units[1]
        #expect(throws: StreamDecodeFailure.awaitingKeyframe) { try StreamDecoder().decode(withP[...]) }
    }

    /// An access unit with no slices is no picture, and changes nothing.
    @Test func parameterSetsAloneAreNoPicture() throws {
        let units = try Self.bars.get()
        let decoder = StreamDecoder()
        _ = try decoder.decode(units[0][...])
        let large = Self.parameterSetsOnly(try Self.large.get()[0])
        #expect(throws: StreamDecodeFailure.noPicture) { try decoder.decode(large[...]) }
        let buffer = try decoder.decode(units[1][...])
        #expect(CVPixelBufferGetWidth(buffer) < 256)
    }

    @Test func recordedParameterSetsDescribe2560x1440() throws {
        let sets = ParameterSets(sps: AnnexBTests.recordedSPS, pps: AnnexBTests.recordedPPS)
        let format = try StreamDecoder.formatDescription(sets)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == 2560 && size.height == 1440)
    }

    static func parameterSetsOnly(_ accessUnit: [UInt8]) -> [UInt8] {
        AnnexB.units(in: accessUnit[...]).filter { !$0.isSliceData }.flatMap { [0, 0, 0, 1] + $0.bytes }
    }
}
