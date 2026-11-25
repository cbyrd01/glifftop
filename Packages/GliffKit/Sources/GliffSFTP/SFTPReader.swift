/// Reads a packet's body: big-endian integers and length-prefixed strings, kept as bytes.
/// Every read past the end throws `.truncated`.
public struct SFTPReader: Sendable {
    /// The longest string the host may send, except DATA's bytes: a name, a handle, an
    /// extension's name or value.
    public static let maxString = 4096
    /// The most name-and-value pairs a VERSION or an ATTRS may list.
    public static let maxPairs = 64

    private let bytes: [UInt8]
    private var index = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - index }
    public var isAtEnd: Bool { remaining == 0 }

    public mutating func byte() throws(SFTPError) -> UInt8 {
        guard remaining >= 1 else { throw .truncated }
        defer { index += 1 }
        return bytes[index]
    }

    public mutating func uint32() throws(SFTPError) -> UInt32 {
        UInt32(try integer(4))
    }

    public mutating func uint64() throws(SFTPError) -> UInt64 {
        try integer(8)
    }

    /// A string of at most `max` bytes.
    public mutating func string(max: Int = maxString) throws(SFTPError) -> [UInt8] {
        let range = try stringRange(max: max)
        return Array(bytes[range])
    }

    /// Reads past a string of at most `max` bytes, keeping nothing.
    public mutating func skipString(max: Int = maxString) throws(SFTPError) {
        _ = try stringRange(max: max)
    }

    /// Everything left.
    public mutating func rest() -> [UInt8] {
        defer { index = bytes.count }
        return Array(bytes[index...])
    }

    private mutating func stringRange(max: Int) throws(SFTPError) -> Range<Int> {
        let length = Int(try uint32())
        guard length <= remaining else { throw .truncated }
        guard length <= max else { throw .stringTooLong }
        defer { index += length }
        return index..<index + length
    }

    private mutating func integer(_ width: Int) throws(SFTPError) -> UInt64 {
        guard remaining >= width else { throw .truncated }
        defer { index += width }
        return bytes[index..<index + width].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
