import Testing

@testable import GliffProtocol

/// Returns the bytes `write` produces.
private func encode(_ write: (inout CBORWriter) -> Void) -> [UInt8] {
    var writer = CBORWriter()
    write(&writer)
    return writer.bytes
}

/// Reads one value with `read`, and expects it to consume all of `bytes`.
private func decode<T>(
    _ bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation,
    _ read: (inout CBORReader) throws -> T
) throws -> T {
    var reader = CBORReader(bytes)
    let value = try read(&reader)
    #expect(reader.isAtEnd, sourceLocation: sourceLocation)
    return value
}

/// Expects `read` to throw `error` on `bytes`.
private func expectThrows<T>(
    _ error: ProtocolError, _ bytes: [UInt8], _ read: (inout CBORReader) throws -> T,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var reader = CBORReader(bytes)
    #expect(throws: error, sourceLocation: sourceLocation) { try read(&reader) }
}

@Suite struct CBORTests {
    // MARK: - Round trips (RFC 8949 Appendix A)

    @Test(
        arguments: [
            (UInt64(0), [0x00]), (23, [0x17]), (24, [0x18, 0x18]), (100, [0x18, 0x64]),
            (1000, [0x19, 0x03, 0xe8]), (1_000_000, [0x1a, 0x00, 0x0f, 0x42, 0x40]),
            (1_000_000_000_000, [0x1b, 0x00, 0x00, 0x00, 0xe8, 0xd4, 0xa5, 0x10, 0x00]),
            (UInt64.max, [0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
        ] as [(UInt64, [UInt8])])
    func unsignedRoundTrip(value: UInt64, encoded: [UInt8]) throws {
        #expect(encode { $0.unsigned(value) } == encoded)
        #expect(try decode(encoded) { try $0.unsigned() } == value)
    }

    @Test(
        arguments: [
            (Int64(10), [0x0a]), (-1, [0x20]), (-10, [0x29]), (-100, [0x38, 0x63]),
            (-1000, [0x39, 0x03, 0xe7]),
            (Int64.min, [0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
            (Int64.max, [0x1b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
        ] as [(Int64, [UInt8])])
    func signedRoundTrip(value: Int64, encoded: [UInt8]) throws {
        #expect(encode { $0.signed(value) } == encoded)
        #expect(try decode(encoded) { try $0.signed() } == value)
    }

    @Test func boolsAndNull() throws {
        #expect(encode { $0.bool(false) } == [0xf4])
        #expect(encode { $0.bool(true) } == [0xf5])
        #expect(encode { $0.null() } == [0xf6])
        #expect(try decode([0xf4]) { try $0.bool() } == false)
        #expect(try decode([0xf5]) { try $0.bool() } == true)
        try decode([0xf6]) { try $0.null() }
    }

    @Test(
        arguments: [
            ("", [0x60]), ("a", [0x61, 0x61]), ("ü", [0x62, 0xc3, 0xbc]),
            ("IETF", [0x64, 0x49, 0x45, 0x54, 0x46]),
        ] as [(String, [UInt8])])
    func textRoundTrip(value: String, encoded: [UInt8]) throws {
        #expect(encode { $0.text(value) } == encoded)
        #expect(try decode(encoded) { try $0.text() } == value)
    }

    /// Accents and emoji survive byte for byte.
    @Test func nonASCIITextRoundTrip() throws {
        let name = "Résumé 📄.txt"
        let encoded = encode { $0.text(name) }
        #expect(encoded == [0x71] + Array(name.utf8))  // 17 UTF-8 bytes
        #expect(try decode(encoded) { try $0.text() } == name)
    }

    @Test func byteStringRoundTrip() throws {
        #expect(encode { $0.byteString([1, 2, 3, 4]) } == [0x44, 1, 2, 3, 4])
        #expect(encode { $0.byteString([]) } == [0x40])
        let long = [UInt8](repeating: 7, count: 24)
        #expect(encode { $0.byteString(long) } == [0x58, 0x18] + long)
        #expect(try decode([0x44, 1, 2, 3, 4]) { try $0.byteString() } == [1, 2, 3, 4])
        #expect(try decode([0x58, 0x18] + long) { try $0.byteString() } == long)
    }

    @Test func arrayRoundTrip() throws {
        let bytes = encode {
            $0.arrayHeader(count: 3)
            for item: UInt64 in 1...3 { $0.unsigned(item) }
        }
        #expect(bytes == [0x83, 1, 2, 3])
        var reader = CBORReader(bytes)
        #expect(try reader.arrayHeader() == 3)
        #expect(try [reader.unsigned(), reader.unsigned(), reader.unsigned()] == [1, 2, 3])
        #expect(reader.isAtEnd)
        #expect(encode { $0.arrayHeader(count: 25) } == [0x98, 0x19])
    }

    @Test func indefiniteArrayHeaderIsNil() throws {
        var reader = CBORReader([0x9f, 0xff])
        #expect(try reader.arrayHeader() == nil)
        #expect(try reader.peekIsBreak())
    }

    @Test func floatsEncodeAtTheirOwnWidth() throws {
        #expect(encode { $0.float64(1.1) } == [0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a])
        #expect(encode { $0.float32(100_000.0) } == [0xfa, 0x47, 0xc3, 0x50, 0x00])
        #expect(encode { $0.float64(1.0) } == [0xfb, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0])
        #expect(
            try decode([0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a]) { try $0.double() } == 1.1)
        #expect(try decode([0xfa, 0x47, 0xc3, 0x50, 0x00]) { try $0.float32() } == 100_000.0)
    }

    // MARK: - Float widths from a future peer

    @Test(
        arguments: [
            ([0xf9, 0x3c, 0x00], 1.0), ([0xf9, 0x00, 0x00], 0.0), ([0xf9, 0xc4, 0x00], -4.0),
            ([0xf9, 0x7b, 0xff], 65504.0), ([0xf9, 0x00, 0x01], 5.960464477539063e-8),
            ([0xf9, 0x04, 0x00], 0.00006103515625), ([0xf9, 0x7c, 0x00], .infinity),
            ([0xf9, 0xfc, 0x00], -.infinity), ([0xfa, 0x47, 0xc3, 0x50, 0x00], 100_000.0),
        ] as [([UInt8], Double)])
    func doubleAcceptsHalfAndSingle(encoded: [UInt8], value: Double) throws {
        #expect(try decode(encoded) { try $0.double() } == value)
    }

    @Test func halfFloatNaN() throws {
        #expect(try decode([0xf9, 0x7e, 0x00]) { try $0.double() }.isNaN)
        #expect(try decode([0xf9, 0x7e, 0x00]) { try $0.float32() }.isNaN)
    }

    @Test func float32AcceptsHalfButNotDouble() throws {
        #expect(try decode([0xf9, 0x3c, 0x00]) { try $0.float32() } == 1.0)
        expectThrows(.unexpectedType(expected: "float32", found: 0xfb), [0xfb, 0, 0, 0, 0, 0, 0, 0, 0]) {
            try $0.float32()
        }
    }

    // MARK: - Integer ranges

    @Test func unsignedAsNarrowType() throws {
        #expect(try decode([0x1a, 0xff, 0xff, 0xff, 0xff]) { try $0.unsigned(as: UInt32.self) } == .max)
        expectThrows(.integerOverflow, [0x1b, 0, 0, 0, 1, 0, 0, 0, 0]) { try $0.unsigned(as: UInt32.self) }
        expectThrows(.integerOverflow, [0x1a, 0x00, 0x01, 0x11, 0x70]) { try $0.unsigned(as: UInt16.self) }
    }

    @Test func int32Range() throws {
        #expect(try decode([0x3a, 0x7f, 0xff, 0xff, 0xff]) { try $0.int32() } == .min)
        #expect(try decode([0x1a, 0x7f, 0xff, 0xff, 0xff]) { try $0.int32() } == .max)
        expectThrows(.integerOverflow, [0x1a, 0x80, 0, 0, 0]) { try $0.int32() }
        expectThrows(.integerOverflow, [0x3a, 0x80, 0, 0, 0]) { try $0.int32() }
    }

    @Test func signedRange() throws {
        expectThrows(.integerOverflow, [0x1b, 0x80, 0, 0, 0, 0, 0, 0, 0]) { try $0.signed() }
        expectThrows(.integerOverflow, [0x3b, 0x80, 0, 0, 0, 0, 0, 0, 0]) { try $0.signed() }
    }

    // MARK: - Hostile or corrupt input

    @Test func hugeTextLengthIsTruncatedNotAllocated() {
        expectThrows(.truncated, [0x7b, 0, 0, 0x01, 0, 0, 0, 0, 0]) { try $0.text() }
        expectThrows(.truncated, [0x5b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]) {
            try $0.byteString()
        }
        expectThrows(.truncated, [0x63, 0x61]) { try $0.text() }
    }

    @Test func hugeArrayCountIsTruncated() {
        expectThrows(.truncated, [0x9a, 0xff, 0xff, 0xff, 0xff]) { try $0.arrayHeader() }
        expectThrows(.truncated, [0x9a, 0xff, 0xff, 0xff, 0xff]) { try $0.skip() }
        expectThrows(.truncated, [0xbb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]) { try $0.skip() }
    }

    @Test func shortInputIsTruncated() {
        expectThrows(.truncated, []) { try $0.unsigned() }
        expectThrows(.truncated, [0x18]) { try $0.unsigned() }
        expectThrows(.truncated, [0x19, 0x03]) { try $0.unsigned() }
        expectThrows(.truncated, [0xfa, 0x47]) { try $0.double() }
        expectThrows(.truncated, [0x82, 0x01]) { try $0.skip() }
        expectThrows(.truncated, [0x9f, 0x01]) { try $0.skip() }
        expectThrows(.truncated, []) { try $0.peekIsNull() }
    }

    @Test func invalidUTF8() {
        expectThrows(.invalidUTF8, [0x62, 0xc3, 0x28]) { try $0.text() }
    }

    @Test func wrongTypeNamesTheInitialByte() {
        expectThrows(.unexpectedType(expected: "unsigned", found: 0x61), [0x61, 0x61]) { try $0.unsigned() }
        expectThrows(.unexpectedType(expected: "unsigned", found: 0x1c), [0x1c]) { try $0.unsigned() }
        expectThrows(.unexpectedType(expected: "text", found: 0x7f), [0x7f, 0xff]) { try $0.text() }
        expectThrows(.unexpectedType(expected: "bool", found: 0xf6), [0xf6]) { try $0.bool() }
        expectThrows(.unexpectedType(expected: "null", found: 0x01), [0x01]) { try $0.null() }
        expectThrows(.unexpectedType(expected: "array", found: 0xa0), [0xa0]) { try $0.arrayHeader() }
        expectThrows(.unexpectedType(expected: "item", found: 0xff), [0xff]) { try $0.skip() }
    }

    /// RFC 8949 §3.2.3: an indefinite-length string's chunks are definite strings of its type.
    @Test func indefiniteStringChunksMustMatch() {
        expectThrows(.unexpectedType(expected: "byte string chunk", found: 0x01), [0x5f, 0x01, 0xff]) {
            try $0.skip()
        }
        expectThrows(.unexpectedType(expected: "text chunk", found: 0x41), [0x7f, 0x41, 0x00, 0xff]) {
            try $0.skip()
        }
        expectThrows(.unexpectedType(expected: "byte string chunk", found: 0x5f), [0x5f, 0x5f, 0xff, 0xff]) {
            try $0.skip()
        }
    }

    /// RFC 8949 §3.3: a two-byte simple value below 32 is not well formed.
    @Test func shortSimpleValueInTwoBytesIsRejected() {
        expectThrows(.unexpectedType(expected: "item", found: 0xf8), [0xf8, 0x00]) { try $0.skip() }
        expectThrows(.unexpectedType(expected: "item", found: 0xf8), [0xf8, 0x1f]) { try $0.skip() }
    }

    // MARK: - Peeking and skipping

    @Test func peeksDoNotConsume() throws {
        let reader = CBORReader([0xf6])
        #expect(try reader.peekIsNull())
        #expect(try !reader.peekIsBreak())
        #expect(!reader.isAtEnd)
        #expect(try !CBORReader([0x01]).peekIsNull())
        #expect(try CBORReader([0xff]).peekIsBreak())
    }

    @Test func breakMarkerEndsAnIndefiniteArray() throws {
        try decode([0x9f, 0xff]) {
            #expect(try $0.arrayHeader() == nil)
            try $0.breakMarker()
        }
        expectThrows(.unexpectedType(expected: "break", found: 0xf6), [0xf6]) { try $0.breakMarker() }
    }

    @Test(
        arguments: [
            [0x82, 0x01, 0x9f, 0x02, 0x03, 0xff],  // definite and indefinite arrays nested
            [0xa2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x82, 0x02, 0x03],  // {"a": 1, "b": [2, 3]}
            [0xbf, 0x61, 0x61, 0x01, 0xff],  // indefinite map
            [0xc1, 0x1a, 0x51, 0x4b, 0x67, 0xb0],  // tag 1 (epoch time)
            [0x5f, 0x42, 0x01, 0x02, 0x43, 0x03, 0x04, 0x05, 0xff],  // indefinite byte string
            [0x7f, 0x61, 0x61, 0x61, 0x62, 0xff],  // indefinite text
            [0x83, 0xf4, 0xf7, 0xf8, 0x20],  // simple values, including a one-byte one
            [0x83, 0xf9, 0x3c, 0x00, 0xfa, 0, 0, 0, 0, 0xfb, 0, 0, 0, 0, 0, 0, 0, 0],  // floats
            [0x3b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],  // the most negative integer
        ] as [[UInt8]])
    func skipConsumesOneWholeItem(item: [UInt8]) throws {
        var reader = CBORReader(item + [0x05])
        try reader.skip()
        #expect(try reader.unsigned() == 5)
        #expect(reader.isAtEnd)
    }

    @Test func skipSurvivesDeepNesting() throws {
        try decode([UInt8](repeating: 0x81, count: 100_000) + [0x00]) { try $0.skip() }
    }
}
