import Testing

@testable import FixtureEncoding

struct SPSRewriterTests {
    /// An SPS recorded from gliff-server 0.4.3 (NVIDIA): High, level 5.2, 2560×1440, no VUI.
    static let recordedSPS: [UInt8] = [
        0x67, 0x64, 0x00, 0x34, 0xAC, 0x1B, 0x1A, 0x80, 0x28, 0x00, 0xB5, 0x90,
    ]

    @Test func recordedSPSIsUnchanged() throws {
        #expect(try SPSRewriter.withoutVUI(Self.recordedSPS) == Self.recordedSPS)
    }

    /// The same SPS with a VUI (video signal type, colour description, bitstream restriction)
    /// comes back as the recorded one.
    @Test func vuiIsStripped() throws {
        let withVUI = try Self.recordedWithVUI()
        #expect(withVUI != Self.recordedSPS)
        #expect(try SPSRewriter.withoutVUI(withVUI) == Self.recordedSPS)
    }

    @Test func truncatedSPSThrows() {
        #expect(throws: BitReader.EndOfData.self) {
            try SPSRewriter.withoutVUI(Array(Self.recordedSPS.prefix(5)))
        }
    }

    @Test func emulationPreventionRoundTrips() {
        let rbsp: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x03, 0x7F]
        let escaped = Escaping.escape(rbsp)
        #expect(escaped == [0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x03, 0x03, 0x7F])
        #expect(Escaping.unescape(escaped) == rbsp)
    }

    /// The recorded SPS fields up to the VUI flag, then a VUI and the stop bit.
    private static func recordedWithVUI() throws -> [UInt8] {
        let rbsp = Escaping.unescape(Array(recordedSPS.dropFirst()))
        let vuiFlagAt = try SPSRewriter.vuiFlagPosition(rbsp: rbsp)
        var writer = BitWriter()
        var reader = BitReader(rbsp)
        try writer.copy(vuiFlagAt, from: &reader)
        writer.write(bit: 1)  // vui_parameters_present_flag
        writer.write(bits: 0, count: 2)  // aspect ratio, overscan info: absent
        writer.write(bit: 1)  // video_signal_type_present_flag
        writer.write(bits: 5, count: 3)  // video_format: unspecified
        writer.write(bit: 0)  // video_full_range_flag
        writer.write(bit: 1)  // colour_description_present_flag
        writer.write(bits: 0x01_01_01, count: 24)  // BT.709 primaries, transfer, matrix
        writer.write(bits: 0, count: 5)  // chroma loc, timing, nal hrd, vcl hrd, pic struct
        writer.write(bit: 1)  // bitstream_restriction_flag
        writer.write(bit: 1)  // motion_vectors_over_pic_boundaries_flag
        for value: UInt32 in [0, 0, 16, 16, 0, 1] { writer.write(ue: value) }
        writer.writeTrailingBits()
        return [recordedSPS[0]] + Escaping.escape(writer.bytes)
    }
}

extension SPSRewriterTests {
    /// A scaling-list delta outside -128…127 is corrupt: it throws rather than overflowing.
    @Test func hugeScalingListDeltaThrows() {
        var writer = BitWriter()
        writer.write(bits: 0x64_00_34, count: 24)  // High, level 5.2
        for value: UInt32 in [0, 1, 0, 0] { writer.write(ue: value) }  // id, 4:2:0, 8-bit, 8-bit
        writer.write(bits: 0b011, count: 3)  // no bypass; scaling matrix; list 0 present
        writer.write(ue: 0xFFFF_FFFD)  // delta_scale se = 2^31 - 1
        writer.writeTrailingBits()
        #expect(throws: SPSRewriter.Malformed.self) {
            try SPSRewriter.withoutVUI([0x67] + Escaping.escape(writer.bytes))
        }
    }
}
