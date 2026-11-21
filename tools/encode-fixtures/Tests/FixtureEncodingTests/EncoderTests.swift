import Testing

@testable import FixtureEncoding

struct EncoderTests {
    /// 4×2 luma, 2×1 chroma pairs: a shift of 1 moves luma 2 pixels and chroma 1 pair, wrapping.
    @Test func shiftMovesLumaTwoAndChromaOnePairLeft() throws {
        let planes = try NV12(width: 4, height: 2, luma: [0, 1, 2, 3, 4, 5, 6, 7], chroma: [10, 11, 12, 13])
        let shifted = planes.shiftedLeft(by: 1)
        #expect(shifted.luma == [2, 3, 0, 1, 6, 7, 4, 5])
        #expect(shifted.chroma == [12, 13, 10, 11])
        #expect(planes.shiftedLeft(by: 0) == planes)
    }

    /// Upstream's shape: the first access unit is SPS, PPS, IDR; the rest one P slice each;
    /// the SPS has no VUI.
    @Test func encodesUpstreamShapedAccessUnits() throws {
        let frames = try (0..<4).map { try Self.gradient().shiftedLeft(by: $0) }
        #expect(try H264Encoder.encode(frames).map(\.types) == [[7, 8, 5], [1], [1], [1]])
    }

    @Test func spsHasNoVUI() throws {
        let first = try H264Encoder.encode([try Self.gradient()])[0]
        let sps = try #require(first.units.first { $0.first.map { $0 & 0x1F } == 7 })
        #expect(try SPSRewriter.withoutVUI(sps) == sps)
    }

    static func gradient() throws -> NV12 {
        let (width, height) = (64, 48)
        let luma = (0..<width * height).map { UInt8(16 + ($0 % width) * 3) }
        let chroma = (0..<width * height / 2).map { UInt8(96 + $0 % 64) }
        return try NV12(width: width, height: height, luma: luma, chroma: chroma)
    }
}

extension EncoderTests {
    @Test func negativeShiftWrapsRight() throws {
        let planes = try NV12(width: 4, height: 2, luma: [0, 1, 2, 3, 4, 5, 6, 7], chroma: [10, 11, 12, 13])
        #expect(planes.shiftedLeft(by: -1) == planes.shiftedLeft(by: 1))
    }

    @Test func planesOfTheWrongSizeThrow() {
        #expect(throws: NV12.WrongSize.self) {
            try NV12(width: 4, height: 2, luma: [0], chroma: [10, 11, 12, 13])
        }
        #expect(throws: NV12.WrongSize.self) {
            try NV12(width: 4, height: 2, luma: Array(repeating: 0, count: 8), chroma: [])
        }
    }
}
