/// Encodes the subset of CBOR (RFC 8949) that Gliff messages use, the way upstream's
/// minicbor does: shortest integer and length encodings, definite-length arrays, and floats
/// at the width asked for (never shortened).
struct CBORWriter {
    private(set) var bytes: [UInt8] = []

    mutating func arrayHeader(count: Int) {
        precondition(count >= 0, "CBOR array count must not be negative (\(count))")
        head(major: 4, argument: UInt64(count))
    }

    mutating func unsigned(_ value: UInt64) {
        head(major: 0, argument: value)
    }

    mutating func signed(_ value: Int64) {
        if value >= 0 {
            head(major: 0, argument: UInt64(value))
        } else {
            // CBOR stores a negative n as -1 - n, which is the bitwise complement.
            head(major: 1, argument: UInt64(bitPattern: ~value))
        }
    }

    mutating func bool(_ value: Bool) {
        bytes.append(value ? 0xf5 : 0xf4)
    }

    mutating func null() {
        bytes.append(0xf6)
    }

    mutating func text(_ value: String) {
        let utf8 = value.utf8
        head(major: 3, argument: UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func byteString(_ value: [UInt8]) {
        head(major: 2, argument: UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func float32(_ value: Float) {
        bytes.append(0xfa)
        appendBigEndian(UInt64(value.bitPattern), byteCount: 4)
    }

    mutating func float64(_ value: Double) {
        bytes.append(0xfb)
        appendBigEndian(value.bitPattern, byteCount: 8)
    }

    /// Writes an initial byte for `major` with `argument` in its shortest form. No
    /// reserveCapacity: an exact-size reserve on every item would defeat the array's
    /// geometric growth and make long messages quadratic.
    private mutating func head(major: UInt8, argument: UInt64) {
        let type = major << 5
        guard argument >= 24 else {
            bytes.append(type | UInt8(argument))
            return
        }
        let width =
            switch argument {
            case ...0xff: 1
            case ...0xffff: 2
            case ...0xffff_ffff: 4
            default: 8
            }
        bytes.append(type | (24 + UInt8(width.trailingZeroBitCount)))  // 24, 25, 26 or 27
        appendBigEndian(argument, byteCount: width)
    }

    /// Appends the low `byteCount` bytes of `value`, most significant first.
    private mutating func appendBigEndian(_ value: UInt64, byteCount: Int) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0.suffix(byteCount)) }
    }
}

extension CBORWriter {
    /// Starts `[variant, [fields…]]`, minicbor's encoding of a message or an enum with data;
    /// the caller then writes exactly `fieldCount` fields.
    mutating func variant(_ index: Int64, fieldCount: Int) {
        arrayHeader(count: 2)
        signed(index)
        arrayHeader(count: fieldCount)
    }

    /// A definite-length array, each element written by `write`.
    mutating func array<Element>(_ elements: [Element], _ write: (inout CBORWriter, Element) -> Void) {
        arrayHeader(count: elements.count)
        for element in elements { write(&self, element) }
    }

    /// An index-only enum: its bare variant index.
    mutating func wireEnum(_ value: some WireEnum) {
        signed(value.rawValue)
    }
}
