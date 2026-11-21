/// Reads an H.264 RBSP (emulation prevention already removed) bit by bit, most significant
/// first.
struct BitReader {
    struct EndOfData: Error {}

    private let bytes: [UInt8]
    /// Bits read so far.
    private(set) var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func bit() throws(EndOfData) -> UInt32 {
        guard position < bytes.count * 8 else { throw EndOfData() }
        defer { position += 1 }
        return UInt32(bytes[position / 8] >> (7 - position % 8) & 1)
    }

    mutating func bits(_ count: Int) throws(EndOfData) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<count { value = value << 1 | (try bit()) }
        return value
    }

    /// Exp-Golomb `ue(v)`.
    mutating func ue() throws(EndOfData) -> UInt32 {
        var zeros = 0
        while try bit() == 0 {
            zeros += 1
            guard zeros < 32 else { throw EndOfData() }
        }
        return (1 << zeros) - 1 + (try bits(zeros))
    }

    /// Exp-Golomb `se(v)`.
    mutating func se() throws(EndOfData) -> Int32 {
        let code = try ue()
        return code % 2 == 1 ? Int32((code + 1) / 2) : -Int32(code / 2)
    }
}

/// Writes an RBSP bit by bit, most significant first.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var count = 0

    mutating func write(bit: UInt32) {
        if count % 8 == 0 { bytes.append(0) }
        bytes[bytes.count - 1] |= UInt8(bit & 1) << (7 - count % 8)
        count += 1
    }

    mutating func write(bits value: UInt32, count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) { write(bit: value >> shift & 1) }
    }

    /// Copies the next `count` bits of `reader`.
    mutating func copy(_ count: Int, from reader: inout BitReader) throws(BitReader.EndOfData) {
        for _ in 0..<count { write(bit: try reader.bit()) }
    }

    /// Exp-Golomb `ue(v)` (the tests use it to build an SPS with a VUI).
    mutating func write(ue value: UInt32) {
        let code = value + 1
        let length = 32 - code.leadingZeroBitCount
        write(bits: 0, count: length - 1)
        write(bits: code, count: length)
    }

    /// `rbsp_trailing_bits`: a stop bit, then zeros to the byte boundary.
    mutating func writeTrailingBits() {
        write(bit: 1)
        while count % 8 != 0 { write(bit: 0) }
    }
}

/// H.264 emulation prevention: a 0x03 after any two zero bytes that precede a byte ≤ 3.
enum Escaping {
    static func escape(_ rbsp: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}
