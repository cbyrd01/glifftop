import Testing

@testable import GliffVideo

struct AnnexBTests {
    /// Parameter sets recorded from gliff-server 0.4.3 (NVIDIA, 2560×1440); they carry no
    /// screen content.
    static let recordedSPS: [UInt8] = [
        0x67, 0x64, 0x00, 0x34, 0xAC, 0x1B, 0x1A, 0x80, 0x28, 0x00, 0xB5, 0x90,
    ]
    static let recordedPPS: [UInt8] = [0x68, 0xEE, 0x3C, 0x30]
    static let fourByte: [UInt8] = [0, 0, 0, 1]
    static let threeByte: [UInt8] = [0, 0, 1]

    @Test func splitsFourAndThreeByteStartCodes() {
        let bytes =
            Self.fourByte + [0x09, 0xF0] + Self.threeByte + [0x65, 0x88, 0x84] + Self.fourByte + [0x41, 0x9A]
        let units = AnnexB.units(in: bytes[...])
        #expect(units.map(\.type) == [9, 5, 1])
        #expect(units.map { Array($0.bytes) } == [[0x09, 0xF0], [0x65, 0x88, 0x84], [0x41, 0x9A]])
    }

    /// Aux payloads are slices of the frame's payload that don't start at 0.
    @Test func honoursSliceStartIndex() {
        let payload =
            [UInt8](repeating: 0xEE, count: 9000) + Self.fourByte + [0x65, 0x88] + Self.threeByte + [0x41]
        let units = AnnexB.units(in: payload[9000...])
        #expect(units.map { Array($0.bytes) } == [[0x65, 0x88], [0x41]])
    }

    @Test func keepsEmulationPreventionBytes() {
        let units = AnnexB.units(in: (Self.fourByte + [0x65, 0x00, 0x00, 0x03, 0x01, 0x7F])[...])
        #expect(units.map { Array($0.bytes) } == [[0x65, 0x00, 0x00, 0x03, 0x01, 0x7F]])
    }

    @Test func trailingZerosAreNotAUnit() {
        let units = AnnexB.units(
            in: (Self.fourByte + [0x65, 0x88, 0x00, 0x00] + Self.fourByte + [0x41, 0x00])[...])
        #expect(units.map { Array($0.bytes) } == [[0x65, 0x88], [0x41]])
    }

    /// Hostile or broken input gives no units rather than an empty or out-of-range one.
    @Test(
        arguments: [
            [], [0, 0], [0, 0, 1], [0, 0, 0, 1], [0, 0, 0, 0, 0], [0x65, 0x88], [0, 0, 1, 0, 0, 1],
        ] as [[UInt8]])
    func degenerateInputGivesNoUnits(bytes: [UInt8]) {
        #expect(AnnexB.units(in: bytes[...]).isEmpty)
    }

    /// A hostile access unit of nothing but start codes is cut off one past the cap, so the
    /// unit list stays small however large the payload.
    @Test func unitCountIsCapped() {
        let bytes = Array([[UInt8]](repeating: [0, 0, 1, 0x41], count: AnnexB.maxUnits * 3).joined())
        #expect(AnnexB.units(in: bytes[...]).count == AnnexB.maxUnits + 1)
    }

    @Test func sampleDropsParameterSetsAndAUD() {
        let bytes =
            Self.fourByte + [0x09, 0xF0] + Self.fourByte + Self.recordedSPS + Self.fourByte + Self.recordedPPS
            + Self.fourByte + [0x65, 0x88, 0x84]
        #expect(AnnexB.sample(from: AnnexB.units(in: bytes[...])) == [0, 0, 0, 3, 0x65, 0x88, 0x84])
    }

    @Test func sampleKeepsEverySlice() {
        let bytes = Self.fourByte + [0x65, 0x88] + Self.threeByte + [0x65, 0x99, 0x77]
        #expect(
            AnnexB.sample(from: AnnexB.units(in: bytes[...])) == [
                0, 0, 0, 2, 0x65, 0x88, 0, 0, 0, 3, 0x65, 0x99, 0x77,
            ])
    }

    /// Only slice data reaches VideoToolbox: SEI (6), end of stream (11), prefix NAL (14),
    /// subset SPS (15) and unspecified types (0) are dropped.
    @Test func sampleKeepsOnlySliceData() {
        var bytes: [UInt8] = []
        for header: UInt8 in [0x06, 0x0B, 0x0E, 0x0F, 0x00 | 0x60, 0x41] {
            bytes += Self.fourByte + [header, 0x9A]
        }
        #expect(AnnexB.sample(from: AnnexB.units(in: bytes[...])) == [0, 0, 0, 2, 0x41, 0x9A])
    }

    /// No slice data means no sample: the decoder must never build an empty one.
    @Test func noSliceDataGivesNoSample() {
        let bytes = Self.fourByte + Self.recordedSPS + Self.fourByte + Self.recordedPPS
        #expect(AnnexB.sample(from: AnnexB.units(in: bytes[...])) == nil)
        #expect(AnnexB.sample(from: []) == nil)
    }

    /// A header with `forbidden_zero_bit` set is corrupt: the unit is dropped.
    @Test func forbiddenZeroBitDropsTheUnit() {
        let bytes = Self.fourByte + [0xE5, 0x88] + Self.fourByte + [0x41, 0x9A]
        #expect(AnnexB.units(in: bytes[...]).map(\.type) == [1])
    }

    @Test func recordedParameterSets() {
        let bytes =
            Self.fourByte + Self.recordedSPS + Self.fourByte + Self.recordedPPS + Self.fourByte + [
                0x65, 0x88, 0x84,
            ]
        #expect(
            ParameterSets(AnnexB.units(in: bytes[...]))
                == ParameterSets(sps: Self.recordedSPS, pps: Self.recordedPPS))
    }

    @Test func noParameterSetsInAPFrame() {
        #expect(ParameterSets(AnnexB.units(in: (Self.fourByte + [0x41, 0x9A])[...])) == nil)
    }

    @Test func anSPSWithoutAPPSIsNotEnough() {
        #expect(ParameterSets(AnnexB.units(in: (Self.fourByte + Self.recordedSPS)[...])) == nil)
    }
}

extension AnnexB {
    /// The sample as bytes, through `sampleSize` and `writeSample`; nil when there are no slices.
    static func sample(from units: [NALUnit]) -> [UInt8]? {
        guard let size = sampleSize(of: units) else { return nil }
        return [UInt8](unsafeUninitializedCapacity: size) { buffer, count in
            writeSample(of: units, into: UnsafeMutableRawBufferPointer(buffer))
            count = size
        }
    }
}
