/// A value that reads itself from CBOR the way upstream's minicbor derive encodes it.
protocol CBORDecodable {
    init(cbor reader: inout CBORReader) throws
}

/// Reads a struct's or message's field list, `[f0, f1, …]`, by minicbor derive's rules:
/// - a field past the end of the list is missing: `nil` if optional, `missingField` if not;
/// - fields after the last one this build knows are skipped;
/// - the list may be definite or indefinite length.
struct FieldReader {
    private var reader: CBORReader
    private let type: String
    /// Fields left in a definite-length list; nil for an indefinite one (ended by a break).
    private var remaining: Int?
    private var index = 0

    /// Reads one field list from `reader` with `body`, then skips any fields `body` left.
    /// `type` names the struct or message in `missingField` errors.
    static func read<T>(
        _ reader: inout CBORReader, type: String, _ body: (inout FieldReader) throws -> T
    ) throws -> T {
        let count = try reader.arrayHeader()
        var fields = FieldReader(reader: reader, type: type, remaining: count)
        let value = try body(&fields)
        while try fields.hasNext() {
            try fields.reader.skip()
            fields.advance()
        }
        if fields.remaining == nil { try fields.reader.breakMarker() }
        reader = fields.reader
        return value
    }

    /// Reads the `[variant, fields]` pair around a message or an enum with data, as minicbor
    /// derive does: exactly a definite two-element array, and the index as an `Int64`. `body`
    /// gets the index and the reader at the fields.
    static func readVariant<T>(
        _ reader: inout CBORReader, _ body: (Int64, inout CBORReader) throws -> T
    ) throws -> T {
        try reader.pairHeader()
        let variant = try reader.signed()
        return try body(variant, &reader)
    }

    /// The next required field, read with `read`.
    mutating func next<T>(_ read: (inout CBORReader) throws -> T) throws -> T {
        guard try hasNext() else { throw ProtocolError.missingField(message: type, index: index) }
        defer { advance() }
        return try read(&reader)
    }

    mutating func next<T: CBORDecodable>() throws -> T {
        try next { try T(cbor: &$0) }
    }

    /// The next optional field: nil if the list has ended or the field is `null`.
    mutating func optional<T>(_ read: (inout CBORReader) throws -> T) throws -> T? {
        guard try hasNext() else { return nil }
        defer { advance() }
        if try reader.peekIsNull() {
            try reader.null()
            return nil
        }
        return try read(&reader)
    }

    mutating func optional<T: CBORDecodable>() throws -> T? {
        try optional { try T(cbor: &$0) }
    }

    /// An optional enum field that is also nil when it holds a value this build doesn't know,
    /// so a newer peer's addition doesn't fail the message (upstream `cbor::optional`).
    mutating func optionalLenient<T: WireEnum>() throws -> T? {
        try optional { T(rawValue: try $0.signed()) } ?? nil
    }

    /// Whether another field is left in the list.
    func hasNext() throws -> Bool {
        if let remaining { return remaining > 0 }
        return try !reader.peekIsBreak()
    }

    private mutating func advance() {
        index += 1
        if let count = remaining { remaining = count - 1 }
    }
}

/// An enum sent as its bare variant index (minicbor `index_only`), read as an `Int64` the
/// way minicbor does: a negative index is unknown, one beyond `Int64` overflows.
protocol WireEnum: CBORDecodable, RawRepresentable<Int64> {}

extension WireEnum {
    init(cbor reader: inout CBORReader) throws {
        let raw = try reader.signed()
        guard let value = Self(rawValue: raw) else {
            throw ProtocolError.unknownEnumValue(type: String(describing: Self.self), value: raw)
        }
        self = value
    }
}

extension Bool: CBORDecodable {
    init(cbor reader: inout CBORReader) throws { self = try reader.bool() }
}

extension String: CBORDecodable {
    init(cbor reader: inout CBORReader) throws { self = try reader.text() }
}

extension Double: CBORDecodable {
    init(cbor reader: inout CBORReader) throws { self = try reader.double() }
}

extension Int32: CBORDecodable {
    init(cbor reader: inout CBORReader) throws { self = try reader.int32() }
}

extension UInt16: CBORDecodable {
    init(cbor reader: inout CBORReader) throws { self = try reader.unsigned(as: UInt16.self) }
}

extension UInt32: CBORDecodable {
    init(cbor reader: inout CBORReader) throws { self = try reader.unsigned(as: UInt32.self) }
}

extension UInt64: CBORDecodable {
    init(cbor reader: inout CBORReader) throws { self = try reader.unsigned() }
}

/// A CBOR array (`Vec<T>`), definite or indefinite length. Byte fields are byte strings
/// instead: read them with `reader.byteString()`, since `[UInt8]` is deliberately not
/// `CBORDecodable`.
extension Array: CBORDecodable where Element: CBORDecodable {
    init(cbor reader: inout CBORReader) throws {
        self = try FieldReader.read(&reader, type: "Array") { f in
            var elements: [Element] = []
            while try f.hasNext() { elements.append(try f.next()) }
            return elements
        }
    }
}
