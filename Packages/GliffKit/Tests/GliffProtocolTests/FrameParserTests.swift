import Testing

@testable import GliffProtocol

@Suite struct FrameParserTests {
    /// Drains every complete frame the parser holds.
    private func drain(_ parser: inout FrameParser) throws -> [Frame] {
        var frames: [Frame] = []
        while let frame = try parser.next() { frames.append(frame) }
        return frames
    }

    private let first = Frame(body: [1, 2, 3], payload: [9, 9])
    private let second = Frame(body: [4], payload: [])

    private func wire() throws -> [UInt8] {
        try Frame.encode(body: first.body, payload: first.payload)
            + Frame.encode(body: second.body, payload: second.payload)
    }

    @Test func wholeFrameInOneChunk() throws {
        var parser = FrameParser()
        parser.append(try Frame.encode(body: [1, 2, 3], payload: [9, 9]))
        #expect(try parser.next() == Frame(body: [1, 2, 3], payload: [9, 9]))
        #expect(try parser.next() == nil)
        #expect(parser.bufferedByteCount == 0)
        #expect(parser.framesParsed == 1)
    }

    @Test func everySplitPoint() throws {
        let bytes = try wire()
        for split in 0...bytes.count {
            var parser = FrameParser()
            parser.append(bytes[..<split])
            var frames = try drain(&parser)
            parser.append(bytes[split...])
            frames += try drain(&parser)
            #expect(frames == [first, second], "split at \(split)")
            #expect(parser.bufferedByteCount == 0)
        }
    }

    @Test func oneByteAtATime() throws {
        var parser = FrameParser()
        var frames: [Frame] = []
        for byte in try wire() {
            parser.append([byte])
            frames += try drain(&parser)
        }
        #expect(frames == [first, second])
    }

    /// A login banner on stdout reads as a header for a ~1.7 GB body ("Welc").
    @Test func bannerFailsFast() {
        var parser = FrameParser()
        // 20 bytes are enough to fail: the parser doesn't wait for the 1.7 GB "body".
        parser.append(Array("Welcome to omarchy!\n".utf8))
        // "Welc" as a little-endian u32.
        #expect(throws: ProtocolError.bodyTooLarge(0x636c_6557)) { try parser.next() }
    }

    @Test func payloadOverLimitFailsBeforeBuffering() throws {
        var parser = FrameParser()
        let header = UInt64(FrameHeader.maxFramePayload + 1) << 32 | 4
        parser.append(withUnsafeBytes(of: header.littleEndian, Array.init))
        #expect(parser.bufferedByteCount == 8)
        #expect(throws: ProtocolError.payloadTooLarge(FrameHeader.maxFramePayload + 1)) {
            try parser.next()
        }
    }

    /// A multi-MB keyframe arriving as many pipe reads stays linear.
    @Test(.timeLimit(.minutes(1))) func largeFrameInSmallChunksIsLinear() throws {
        let payload = (0..<(32 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let bytes = try Frame.encode(body: [7], payload: payload)
        var parser = FrameParser()
        var frames: [Frame] = []
        var start = 0
        while start < bytes.count {
            let end = min(start + 16 * 1024, bytes.count)
            parser.append(bytes[start..<end])
            frames += try drain(&parser)
            start = end
        }
        try #require(frames.count == 1)
        #expect(frames[0].body == [7])
        #expect(frames[0].payload == payload)
    }

    @Test func encodeRejectsOversizeBody() {
        #expect(throws: ProtocolError.bodyTooLarge((1 << 20) + 1)) {
            try Frame.encode(body: [UInt8](repeating: 0, count: (1 << 20) + 1))
        }
    }

    @Test func encodeWritesHeaderBodyPayload() throws {
        #expect(try Frame.encode(body: [1, 2], payload: [3]) == [2, 0, 0, 0, 1, 0, 0, 0, 1, 2, 3])
    }
}

/// The send path's limits, as upstream `write_msg_with_payloads` applies them.
@Suite struct FrameEncodeLimitTests {
    @Test func payloadOverMaxPayloadIsRejected() {
        let over = Int(FrameHeader.maxPayload) + 1
        #expect(throws: ProtocolError.payloadTooLarge(UInt32(over))) {
            try Frame.encode(body: [0], payload: [UInt8](repeating: 0, count: over))
        }
    }
}
