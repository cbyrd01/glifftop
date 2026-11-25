/// Writes a packet: big-endian integers and length-prefixed strings.
public struct SFTPWriter: Sendable {
    /// Four bytes kept for the packet's length, then what was written.
    private var storage: [UInt8] = [0, 0, 0, 0]

    public init() {}

    /// What was written.
    public var bytes: [UInt8] { Array(storage[4...]) }

    public mutating func byte(_ value: UInt8) { storage.append(value) }

    public mutating func uint32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            storage.append(UInt8(value >> UInt32(shift) & 0xFF))
        }
    }

    public mutating func uint64(_ value: UInt64) {
        uint32(UInt32(value >> 32))
        uint32(UInt32(value & 0xFFFF_FFFF))
    }

    public mutating func string(_ value: [UInt8]) {
        uint32(UInt32(value.count))
        storage += value
    }

    public mutating func string(_ value: String) { string(Array(value.utf8)) }

    /// What was written, after its 4-byte length: one packet, without copying what was written.
    public consuming func packet() -> [UInt8] {
        let length = storage.count - 4
        for index in 0..<4 { storage[index] = UInt8(length >> (24 - 8 * index) & 0xFF) }
        return storage
    }
}
