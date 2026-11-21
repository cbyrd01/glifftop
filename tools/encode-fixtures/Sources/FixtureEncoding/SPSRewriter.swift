/// Makes VideoToolbox's SPS look like gliff-server's: the same fields, no VUI.
enum SPSRewriter {
    struct NotAnSPS: Error {}
    struct Malformed: Error {}

    /// `sps` (a NAL unit from its header byte, escaped) without its VUI. An SPS that has none
    /// comes back unchanged.
    static func withoutVUI(_ sps: [UInt8]) throws -> [UInt8] {
        guard let header = sps.first, header & 0x1F == 7 else { throw NotAnSPS() }
        let rbsp = Escaping.unescape(Array(sps.dropFirst()))
        let flagAt = try vuiFlagPosition(rbsp: rbsp)
        var reader = BitReader(rbsp)
        var writer = BitWriter()
        try writer.copy(flagAt, from: &reader)
        guard try reader.bit() == 1 else { return sps }
        writer.write(bit: 0)
        writer.writeTrailingBits()
        return [header] + Escaping.escape(writer.bytes)
    }

    /// The bit offset of `vui_parameters_present_flag` in an SPS's RBSP (H.264 7.3.2.1.1).
    static func vuiFlagPosition(rbsp: [UInt8]) throws -> Int {
        var reader = BitReader(rbsp)
        let profile = try reader.bits(8)
        _ = try reader.bits(16)  // constraint flags, level_idc
        _ = try reader.ue()  // seq_parameter_set_id
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chromaFormat = try reader.ue()
            if chromaFormat == 3 { _ = try reader.bit() }  // separate_colour_plane_flag
            _ = try reader.ue()  // bit_depth_luma_minus8
            _ = try reader.ue()  // bit_depth_chroma_minus8
            _ = try reader.bit()  // qpprime_y_zero_transform_bypass_flag
            if try reader.bit() == 1 {  // seq_scaling_matrix_present_flag
                for list in 0..<(chromaFormat == 3 ? 12 : 8) where try reader.bit() == 1 {
                    try skipScalingList(&reader, size: list < 6 ? 16 : 64)
                }
            }
        }
        _ = try reader.ue()  // log2_max_frame_num_minus4
        switch try reader.ue() {  // pic_order_cnt_type
        case 0:
            _ = try reader.ue()  // log2_max_pic_order_cnt_lsb_minus4
        case 1:
            _ = try reader.bit()  // delta_pic_order_always_zero_flag
            _ = try reader.se()  // offset_for_non_ref_pic
            _ = try reader.se()  // offset_for_top_to_bottom_field
            for _ in 0..<(try reader.ue()) { _ = try reader.se() }  // offset_for_ref_frame
        default:
            break
        }
        _ = try reader.ue()  // max_num_ref_frames
        _ = try reader.bit()  // gaps_in_frame_num_value_allowed_flag
        _ = try reader.ue()  // pic_width_in_mbs_minus1
        _ = try reader.ue()  // pic_height_in_map_units_minus1
        if try reader.bit() == 0 { _ = try reader.bit() }  // frame_mbs_only, mb_adaptive_frame_field
        _ = try reader.bit()  // direct_8x8_inference_flag
        if try reader.bit() == 1 {  // frame_cropping_flag
            for _ in 0..<4 { _ = try reader.ue() }
        }
        return reader.position
    }

    private static func skipScalingList(_ reader: inout BitReader, size: Int) throws {
        var last = 8
        var next = 8
        for _ in 0..<size where next != 0 {
            let delta = Int(try reader.se())
            guard (-128...127).contains(delta) else { throw Malformed() }
            next = (last + delta + 256) % 256
            last = next == 0 ? last : next
        }
    }
}
