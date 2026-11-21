import Testing

@testable import GliffProtocol

@Suite struct FrameHeaderTests {
    @Test func encodesLittleEndianLengths() throws {
        let header = try FrameHeader(bodyLength: 5, payloadLength: 300)
        #expect(header.encoded == [5, 0, 0, 0, 0x2c, 1, 0, 0])
        #expect(try FrameHeader(decoding: [5, 0, 0, 0, 0x2c, 1, 0, 0]) == header)
    }

    @Test func limitsMatchUpstream() {
        #expect(FrameHeader.size == 8)
        #expect(FrameHeader.maxBody == 1_048_576)
        #expect(FrameHeader.maxPayload == 67_108_864)
        #expect(FrameHeader.maxFramePayload == 134_217_728)
    }

    @Test func bodyLimitIsInclusive() throws {
        #expect(
            try FrameHeader(bodyLength: FrameHeader.maxBody, payloadLength: 0).bodyLength
                == FrameHeader.maxBody)
        #expect(throws: ProtocolError.bodyTooLarge(FrameHeader.maxBody + 1)) {
            try FrameHeader(bodyLength: FrameHeader.maxBody + 1, payloadLength: 0)
        }
    }

    @Test func payloadLimitIsInclusive() throws {
        let limit = FrameHeader.maxFramePayload
        #expect(try FrameHeader(bodyLength: 0, payloadLength: limit).payloadLength == limit)
        #expect(throws: ProtocolError.payloadTooLarge(limit + 1)) {
            try FrameHeader(bodyLength: 0, payloadLength: limit + 1)
        }
    }

    /// Upstream checks the body first, so a frame over both limits reports the body.
    @Test func bodyIsCheckedBeforePayload() {
        #expect(throws: ProtocolError.bodyTooLarge(.max)) {
            try FrameHeader(bodyLength: .max, payloadLength: .max)
        }
    }

    @Test func decodingValidatesLimits() {
        #expect(throws: ProtocolError.payloadTooLarge(.max)) {
            try FrameHeader(decoding: [0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff])
        }
    }

    @Test func decodingNeedsEightBytes() {
        #expect(throws: ProtocolError.truncated) { try FrameHeader(decoding: [5, 0, 0, 0, 0x2c, 1, 0]) }
        #expect(throws: ProtocolError.truncated) { try FrameHeader(decoding: [UInt8]()) }
    }

    /// The header can be read straight from a buffer that holds more of the stream.
    @Test func decodingReadsTheFirstEightBytes() throws {
        let header = try FrameHeader(decoding: [5, 0, 0, 0, 0x2c, 1, 0, 0, 0xa0, 0xff])
        #expect(header == (try FrameHeader(bodyLength: 5, payloadLength: 300)))
    }

    /// A shell banner before the protocol fails cleanly instead of asking
    /// for a 1.6 GB body.
    @Test func shellBannerIsRejected() {
        let banner = Array("Welcome ".utf8)  // "Welc" = 0x636c6557 as a little-endian length
        #expect(throws: ProtocolError.bodyTooLarge(0x636c_6557)) { try FrameHeader(decoding: banner) }
    }
}
