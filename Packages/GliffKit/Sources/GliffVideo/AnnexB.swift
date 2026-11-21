/// One H.264 NAL unit, from its header byte on (no start code).
struct NALUnit: Equatable {
    /// `nal_unit_type`: 1 slice, 5 IDR slice, 7 SPS, 8 PPS, 9 access unit delimiter, …
    let type: UInt8
    let bytes: ArraySlice<UInt8>

    static let sps: UInt8 = 7
    static let pps: UInt8 = 8
    static let idr: UInt8 = 5

    /// Coded slices (types 1–5), the only units the decoded sample carries. Parameter sets
    /// travel in the format description; SEI, delimiters and the rest are left out.
    var isSliceData: Bool { (1...5).contains(type) }
}

/// H.264 Annex B byte streams, as gliff-server sends each access unit: NAL units behind
/// `00 00 01` or `00 00 00 01` start codes.
enum AnnexB {
    /// More NAL units than any real access unit has (a 4096×4096 picture with a slice per
    /// macroblock row has 256): `units` stops one past it, so a hostile payload of start codes
    /// can't build a list ten times its size.
    static let maxUnits = 4096

    /// The NAL units in `bytes`, in order. Bytes before the first start code, and the zeros
    /// before each start code or at the end, belong to no unit; empty units are skipped.
    /// Emulation prevention bytes stay in (VideoToolbox wants them). At most `maxUnits + 1`
    /// units come back; more than `maxUnits` means the access unit is broken.
    static func units(in bytes: ArraySlice<UInt8>) -> [NALUnit] {
        var units: [NALUnit] = []
        var start: Int?
        var zeros = 0
        func close(at end: Int) {
            // A set forbidden_zero_bit marks a corrupt unit.
            guard let start, start < end, bytes[start] & 0x80 == 0 else { return }
            units.append(NALUnit(type: bytes[start] & 0x1F, bytes: bytes[start..<end]))
        }
        for index in bytes.indices {
            let byte = bytes[index]
            if byte == 0 {
                zeros += 1
                continue
            }
            if byte == 1, zeros >= 2 {
                close(at: index - zeros)
                if units.count > maxUnits { return units }
                start = index + 1
            }
            zeros = 0
        }
        close(at: bytes.endIndex - zeros)
        return units
    }

    /// The size of the slices as one length-prefixed sample (4-byte big-endian lengths), the
    /// form VideoToolbox decodes; nil when there are none.
    static func sampleSize(of units: [NALUnit]) -> Int? {
        let size = units.reduce(0) { $0 + ($1.isSliceData ? 4 + $1.bytes.count : 0) }
        return size > 0 ? size : nil
    }

    /// Writes that sample into `buffer`, which holds exactly `sampleSize(of: units)` bytes.
    static func writeSample(of units: [NALUnit], into buffer: UnsafeMutableRawBufferPointer) {
        var offset = 0
        for unit in units where unit.isSliceData {
            buffer.storeBytes(of: UInt32(unit.bytes.count).bigEndian, toByteOffset: offset, as: UInt32.self)
            let body = UnsafeMutableRawBufferPointer(
                rebasing: buffer[offset + 4..<offset + 4 + unit.bytes.count])
            body.copyBytes(from: unit.bytes)
            offset += 4 + unit.bytes.count
        }
    }
}

/// The SPS and PPS an IDR access unit carries in-band.
struct ParameterSets: Equatable {
    let sps: [UInt8]
    let pps: [UInt8]
}

extension ParameterSets {
    /// The first SPS and first PPS in `units`; nil unless both are there. gliff-server sends
    /// exactly one of each, before every IDR.
    init?(_ units: [NALUnit]) {
        guard let sps = units.first(where: { $0.type == NALUnit.sps }),
            let pps = units.first(where: { $0.type == NALUnit.pps })
        else { return nil }
        self.init(sps: Array(sps.bytes), pps: Array(pps.bytes))
    }
}
