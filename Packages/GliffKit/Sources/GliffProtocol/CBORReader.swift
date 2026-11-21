/// Decodes the subset of CBOR (RFC 8949) that Gliff messages use. Input is hostile: every
/// length and count is checked against the bytes left before anything is sliced, and `skip()`
/// is iterative, so deep nesting can't overflow the stack (its memory is at most linear in the
/// input, which the frame limit caps at 1 MiB).
///
/// A method that throws may already have consumed input, so the reader is then unusable. To
/// try a read and fall back (say, to `skip()` an unknown value), read from a copy and keep it
/// only on success: the reader is a value type, so `var attempt = reader` is the checkpoint.
struct CBORReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { position == bytes.count }

    private var remaining: Int { bytes.count - position }

    func peekIsNull() throws -> Bool {
        try peekByte() == 0xf6
    }

    func peekIsBreak() throws -> Bool {
        try peekByte() == 0xff
    }

    /// The array's element count, or nil for an indefinite-length array (ended by a break).
    mutating func arrayHeader() throws -> Int? {
        guard let count = try head("array", majors: 4...4).argument else { return nil }
        return try checkedCount(count, bytesEach: 1)
    }

    /// Consumes the break that ends an indefinite-length item.
    mutating func breakMarker() throws {
        _ = try consumeSimple("break") { $0 == 0xff }
    }

    /// The head of a definite two-element array: minicbor's `[variant, fields]` around a
    /// message or an enum with data. `unexpectedType` for anything else.
    /// The count isn't checked against the bytes left, as minicbor doesn't: an unknown message
    /// is then skipped even when its field list is missing.
    mutating func pairHeader() throws {
        let initial = try peekByte()
        guard try head("array", majors: 4...4).argument == 2 else {
            throw ProtocolError.unexpectedType(expected: "2-element array", found: initial)
        }
    }

    mutating func unsigned() throws -> UInt64 {
        try definiteHead("unsigned", majors: 0...0).argument
    }

    /// An unsigned integer that must fit `T`; `integerOverflow` if it doesn't.
    mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(as _: T.Type) throws -> T {
        guard let value = T(exactly: try unsigned()) else { throw ProtocolError.integerOverflow }
        return value
    }

    mutating func signed() throws -> Int64 {
        let (initial, magnitude) = try definiteHead("signed", majors: 0...1)
        guard magnitude <= UInt64(Int64.max) else { throw ProtocolError.integerOverflow }
        // A negative CBOR integer stores n as -1 - n, which is the bitwise complement.
        return initial >> 5 == 0 ? Int64(magnitude) : ~Int64(magnitude)
    }

    mutating func int32() throws -> Int32 {
        guard let value = Int32(exactly: try signed()) else { throw ProtocolError.integerOverflow }
        return value
    }

    mutating func bool() throws -> Bool {
        try consumeSimple("bool") { $0 == 0xf4 || $0 == 0xf5 } == 0xf5
    }

    mutating func null() throws {
        _ = try consumeSimple("null") { $0 == 0xf6 }
    }

    mutating func text() throws -> String {
        let length = try definiteHead("text", majors: 3...3).argument
        guard let value = String(validating: try take(length), as: UTF8.self) else {
            throw ProtocolError.invalidUTF8
        }
        return value
    }

    mutating func byteString() throws -> [UInt8] {
        Array(try take(try definiteHead("byte string", majors: 2...2).argument))
    }

    /// A half- or single-precision float.
    mutating func float32() throws -> Float {
        Float(try float("float32", allowingDouble: false))  // exact: f16 and f32 fit a Float
    }

    /// A half-, single- or double-precision float, whatever width the peer chose.
    mutating func double() throws -> Double {
        try float("float", allowingDouble: true)
    }

    /// Skips one whole item of any type: nested containers, tags and indefinite lengths too.
    mutating func skip() throws {
        // The open containers, innermost last. A container is dropped as soon as its last item
        // starts, so single-item nesting (0x81 0x81 …) needs no extra memory.
        var open: [Container] = [.counted(1)]
        while let innermost = open.last {
            switch innermost {
            case .counted(let items):
                if items == 1 { open.removeLast() } else { open[open.count - 1] = .counted(items - 1) }
            case .indefinite:
                if try peekIsBreak() {
                    position += 1
                    open.removeLast()
                    continue
                }
            case .chunks(let major, let expected):
                if try peekIsBreak() {
                    position += 1
                    open.removeLast()
                } else {
                    // RFC 8949 §3.2.3: each chunk is a definite string of the same type.
                    _ = try take(try definiteHead(expected, majors: major...major).argument)
                }
                continue
            }
            if let contents = try skipHead() { open.append(contents) }
        }
    }

    // MARK: - Items

    /// What an item contains that `skip()` must still skip: a number of items (never zero),
    /// items up to a break, or an indefinite-length string's chunks up to a break.
    private enum Container {
        case counted(Int)
        case indefinite
        case chunks(major: UInt8, expected: String)
    }

    /// Consumes one item's head, and a definite string's bytes. Returns what is left to skip
    /// inside it, or nil if the head was the whole item.
    private mutating func skipHead() throws -> Container? {
        let (initial, argument) = try head("item", majors: 0...7)
        switch (initial >> 5, argument) {
        case (2, let length?), (3, let length?):
            _ = try take(length)
            return nil
        case (2, nil):
            return .chunks(major: 2, expected: "byte string chunk")
        case (3, nil):
            return .chunks(major: 3, expected: "text chunk")
        case (4, nil), (5, nil):
            return .indefinite
        case (4, let count?):
            let items = try checkedCount(count, bytesEach: 1)
            return items == 0 ? nil : .counted(items)
        case (5, let count?):
            let pairs = try checkedCount(count, bytesEach: 2)
            return pairs == 0 ? nil : .counted(pairs * 2)
        case (6, _?):
            return .counted(1)  // a tag, then the item it tags
        case (7, let value?) where initial == 0xf8 && value < 32:
            // RFC 8949 §3.3: simple values below 32 must use the one-byte form.
            throw ProtocolError.unexpectedType(expected: "item", found: initial)
        case (0, _?), (1, _?), (7, _?):
            return nil  // integers, simple values and floats are all head
        default:
            throw ProtocolError.unexpectedType(expected: "item", found: initial)
        }
    }

    /// Consumes a float of any width the caller accepts; f64 only if `allowingDouble`.
    private mutating func float(_ expected: String, allowingDouble: Bool) throws -> Double {
        switch try consumeSimple(
            expected, where: { $0 == 0xf9 || $0 == 0xfa || (allowingDouble && $0 == 0xfb) })
        {
        case 0xf9:
            return Self.halfToDouble(UInt16(try readBigEndian(byteCount: 2)))
        case 0xfa:
            return Double(Float(bitPattern: UInt32(try readBigEndian(byteCount: 4))))
        default:
            return Double(bitPattern: try readBigEndian(byteCount: 8))
        }
    }

    // MARK: - Primitives

    private func peekByte() throws -> UInt8 {
        guard position < bytes.count else { throw ProtocolError.truncated }
        return bytes[position]
    }

    /// Consumes and returns the next byte if `accepts` it; otherwise throws `unexpectedType`.
    private mutating func consumeSimple(_ expected: String, where accepts: (UInt8) -> Bool) throws -> UInt8 {
        let initial = try peekByte()
        guard accepts(initial) else { throw ProtocolError.unexpectedType(expected: expected, found: initial) }
        position += 1
        return initial
    }

    /// Consumes an initial byte whose major type is in `majors`, and its argument: the value,
    /// length or count, or nil for indefinite length. Checks the type before reading further.
    private mutating func head(_ expected: String, majors: ClosedRange<UInt8>) throws -> (
        initial: UInt8, argument: UInt64?
    ) {
        let initial = try peekByte()
        guard majors.contains(initial >> 5) else {
            throw ProtocolError.unexpectedType(expected: expected, found: initial)
        }
        let info = initial & 0x1f
        switch info {
        case 0..<24:
            position += 1
            return (initial, UInt64(info))
        case 24...27:
            position += 1
            return (initial, try readBigEndian(byteCount: 1 << (info - 24)))
        case 31:
            position += 1
            return (initial, nil)
        default:  // 28-30 are reserved
            throw ProtocolError.unexpectedType(expected: expected, found: initial)
        }
    }

    /// `head`, for items that must have a definite value or length.
    private mutating func definiteHead(_ expected: String, majors: ClosedRange<UInt8>) throws -> (
        initial: UInt8, argument: UInt64
    ) {
        let (initial, argument) = try head(expected, majors: majors)
        guard let argument else { throw ProtocolError.unexpectedType(expected: expected, found: initial) }
        return (initial, argument)
    }

    /// `count` as an Int; throws `truncated` unless `count` items of at least `bytesEach`
    /// bytes could fit in the input left.
    private func checkedCount(_ count: UInt64, bytesEach: Int) throws -> Int {
        guard count <= UInt64(remaining / bytesEach) else { throw ProtocolError.truncated }
        return Int(count)
    }

    private mutating func take(_ length: UInt64) throws -> ArraySlice<UInt8> {
        guard length <= UInt64(remaining) else { throw ProtocolError.truncated }
        let start = position
        position += Int(length)
        return bytes[start..<position]
    }

    private mutating func readBigEndian(byteCount: Int) throws -> UInt64 {
        guard byteCount <= remaining else { throw ProtocolError.truncated }
        var value: UInt64 = 0
        for byte in bytes[position..<position + byteCount] {
            value = value << 8 | UInt64(byte)
        }
        position += byteCount
        return value
    }

    /// IEEE 754 half precision, decoded by hand: sign, 5-bit exponent, 10-bit mantissa.
    private static func halfToDouble(_ bits: UInt16) -> Double {
        let sign: Double = bits & 0x8000 == 0 ? 1 : -1
        let exponent = Int(bits >> 10 & 0x1f)
        let mantissa = Double(bits & 0x3ff)
        switch exponent {
        case 0:
            return sign * mantissa * 0x1p-24  // zero or subnormal
        case 31:
            return mantissa == 0 ? sign * .infinity : .nan
        default:
            return sign * (1024 + mantissa) * Double(sign: .plus, exponent: exponent - 25, significand: 1)
        }
    }
}
