import Testing

@testable import GliffProtocol

@Suite struct ServerMessageFixtureTests {
    @Test func everyServerFixtureHasAnExpectedValue() throws {
        #expect(Set(expectedServerMessages.keys) == Set(try fixtureNames(prefix: "s")))
    }

    @Test func everyHostileFixtureHasAnOutcome() throws {
        #expect(Set(hostileFixtureOutcomes.keys) == Set(try fixtureNames(prefix: "x_")))
    }

    /// What a newer or broken server's message must do, an out-of-range u16 among them.
    @Test(arguments: hostileFixtureOutcomes.keys.sorted())
    func hostileFixture(name: String) throws {
        switch try #require(hostileFixtureOutcomes[name]) {
        case .decodes(let expected): #expect(try ServerMessage.decode(fixture(name)) == expected)
        case .fails(let error): #expect(throws: error) { try ServerMessage.decode(fixture(name)) }
        }
    }

    @Test(arguments: expectedServerMessages.keys.sorted())
    func decodesFixture(name: String) throws {
        #expect(try ServerMessage.decode(fixture(name)) == expectedServerMessages[name])
    }

    @Test func truncatedBodyThrows() throws {
        let body = try fixture("s01_stream_config_dual")
        #expect(throws: ProtocolError.truncated) { try ServerMessage.decode(Array(body.dropLast(3))) }
    }
}

/// Field-list rules beyond the fixtures, from minicbor's derive (upstream's decoder).
@Suite struct ServerMessageFieldTests {
    @Test func missingRequiredFieldThrows() {
        // Error [9, [2]]: no message text.
        #expect(throws: ProtocolError.missingField(message: "Error", index: 1)) {
            try ServerMessage.decode([0x82, 0x09, 0x81, 0x02])
        }
    }

    @Test func nullOptionalFieldIsNil() throws {
        // Error [9, [2, "x", null]]
        #expect(
            try ServerMessage.decode([0x82, 0x09, 0x83, 0x02, 0x61, 0x78, 0xf6])
                == .error(code: 2, message: "x", version: nil))
    }

    @Test func indefiniteLengthFieldListsDecode() throws {
        // [9, [_ 2, "x"]]
        #expect(
            try ServerMessage.decode([0x82, 0x09, 0x9f, 0x02, 0x61, 0x78, 0xff])
                == .error(code: 2, message: "x", version: nil))
    }

    @Test func extraFieldsInIndefiniteListAreSkipped() throws {
        // Ping [12, [_ 55, [1, 2], "future"]]
        #expect(
            try ServerMessage.decode([0x82, 0x0c, 0x9f, 0x18, 0x37, 0x82, 0x01, 0x02, 0x61, 0x66, 0xff])
                == .ping(t: 55))
    }

    /// minicbor wraps a variant in exactly a definite two-element array, nothing else.
    @Test(
        arguments: [
            [0x9f, 0x09, 0x82, 0x02, 0x61, 0x78, 0xff],  // indefinite [_ 9, [2, "x"]]
            [0x83, 0x0c, 0x81, 0x01, 0x00],  // [12, [1], 0]: a third element
            [0x81, 0x0c],  // [12]: no field list
        ] as [[UInt8]])
    func messageEnvelopeMustBeAPair(body: [UInt8]) {
        #expect(throws: ProtocolError.unexpectedType(expected: "2-element array", found: body[0])) {
            try ServerMessage.decode(body)
        }
    }

    /// Upstream skips an unknown message as soon as its variant is read, without parsing
    /// the rest (gliff-transport `is_unknown_message`); minicbor reads the index as an i64.
    @Test(
        arguments: [
            ([0x82, 0x18, 0x63, 0x9f, 0x01, 0xff], 99),  // indefinite fields
            ([0x82, 0x18, 0x63], 99),  // no field list at all
            ([0x82, 0x0d], 13),  // no field list, one-byte index (minicbor doesn't check the count)
            ([0x82, 0x18, 0x63, 0xf8, 0x00], 99),  // fields that aren't valid CBOR
            ([0x82, 0x20, 0x80], -1),  // a negative variant
        ] as [([UInt8], Int64)])
    func unknownMessageIsSkippedUnparsed(body: [UInt8], variant: Int64) throws {
        #expect(try ServerMessage.decode(body) == .unknown(variant: variant))
    }

    @Test func variantBeyondInt64Throws() {
        #expect(throws: ProtocolError.integerOverflow) {
            try ServerMessage.decode([0x82, 0x1b, 0x80, 0, 0, 0, 0, 0, 0, 0, 0x80])
        }
    }

    @Test func unknownClipboardItemThrows() {
        // ClipboardRequest [6, [2, 9, [5, [0]]]]
        #expect(throws: ProtocolError.unknownEnumValue(type: "ClipboardItem", value: 5)) {
            try ServerMessage.decode([0x82, 0x06, 0x83, 0x02, 0x09, 0x82, 0x05, 0x81, 0x00])
        }
    }

    /// An unknown optional enum value decodes as nil, negative ones included (upstream reads
    /// the index as an i64); one beyond the i64 range fails the message, as upstream's does.
    @Test func optionalEnumIndexFollowsI64() throws {
        var body = try fixture("s01_stream_config_dual")
        #expect(body[5] == 0x00)  // pipeline .gpu
        body[5] = 0x20  // -1
        guard case .streamConfig(let config) = try ServerMessage.decode(body) else {
            Issue.record("not streamConfig")
            return
        }
        #expect(config.pipeline == nil)
        let huge: [UInt8] = [0x1b, 0x80, 0, 0, 0, 0, 0, 0, 0]
        let overflowing = Array(body[..<5]) + huge + Array(body[6...])
        #expect(throws: ProtocolError.integerOverflow) { try ServerMessage.decode(overflowing) }
    }

    @Test func negativeRequiredEnumIsUnknown() throws {
        var body = try fixture("s01_stream_config_dual")
        body[4] = 0x20  // chroma -1
        #expect(throws: ProtocolError.unknownEnumValue(type: "ChromaMode", value: -1)) {
            try ServerMessage.decode(body)
        }
    }

    /// A value out of range for a u32 or i32 field throws.
    @Test func outOfRangeFieldsThrow() {
        // VideoFrame [2, [7, 0, true, [], 2^32, 0]]: data_len doesn't fit a u32.
        #expect(throws: ProtocolError.integerOverflow) {
            try ServerMessage.decode([
                0x82, 0x02, 0x86, 0x07, 0x00, 0xf5, 0x80, 0x1b, 0, 0, 0, 1, 0, 0, 0, 0, 0x00,
            ])
        }
        // CursorShape [3, [5, 24, 24, -2^31 - 1, 0, 0]]: hot_x doesn't fit an i32.
        #expect(throws: ProtocolError.integerOverflow) {
            try ServerMessage.decode([
                0x82, 0x03, 0x86, 0x05, 0x18, 0x18, 0x18, 0x18, 0x3a, 0x80, 0, 0, 0, 0x00, 0x00,
            ])
        }
    }

    /// Text keeps the server's exact UTF-8 bytes. String `==` uses canonical
    /// equivalence, so it alone wouldn't catch a decoder that normalized the name.
    @Test func nonASCIIPathKeepsItsBytes() throws {
        guard
            case .clipboard(.offer(_, _, let files)) = try ServerMessage.decode(
                fixture("s05_clipboard_offer"))
        else {
            Issue.record("not an offer")
            return
        }
        let expected: [UInt8] =
            [0x52, 0xc3, 0xa9] + Array("sum".utf8) + [0xc3, 0xa9, 0x20, 0xf0, 0x9f, 0x93, 0x84]
            + Array(".txt".utf8)
        #expect(Array(files[0].path.utf8) == expected)
    }

    @Test func messageMustBeAnArray() {
        #expect(throws: ProtocolError.unexpectedType(expected: "array", found: 0x0c)) {
            try ServerMessage.decode([0x0c])
        }
    }
}
