import Testing

@testable import GliffProtocol

/// The payload sections each server message reads, and upstream's rules for them
/// (`gliff-transport` `read_payload`, `net.rs` `cursor_payload_fits`).
@Suite struct PayloadLengthTests {
    private func sections(_ name: String) throws -> [UInt32]? {
        try ServerMessage.decode(fixture(name)).declaredPayloads
    }

    @Test func videoFrameDeclaresMainThenAux() throws {
        #expect(try sections("s02_video_frame") == [9000, 9500])
    }

    @Test func cursorShapeDeclaresItsPixels() throws {
        #expect(try sections("s03_cursor_shape") == [2304])
    }

    @Test func clipboardDataDeclaresItsChunk() throws {
        #expect(try sections("s07_clipboard_data") == [4096])
    }

    @Test(arguments: [
        "s00_hello_ack", "s01_stream_config_dual", "s04_cursor_pos", "s05_clipboard_offer",
        "s06_clipboard_request", "s08_pong", "s09_error", "s10_clipboard_ack", "s11_clipboard_abort",
        "s12_ping",
    ])
    func otherKnownMessagesDeclareNone(name: String) throws {
        #expect(try sections(name) == [])
    }

    /// An unknown message may carry any payload: the session skips it whole.
    @Test func unknownDeclaresNothing() throws {
        #expect(try sections("x_unknown_variant") == nil)
        #expect(throws: Never.self) { try ServerMessage.unknown(variant: 99).checkPayload(carried: 1 << 20) }
    }

    /// A malformed cursor shape is ignored with its payload, not fatal (upstream `read_cursor`).
    @Test(arguments: [
        CursorShape(id: 1, width: 0, height: 24, hotX: 0, hotY: 0, argbLength: 0),
        CursorShape(id: 1, width: 1025, height: 1, hotX: 0, hotY: 0, argbLength: 1025 * 4),
        CursorShape(id: 1, width: 24, height: 24, hotX: 0, hotY: 0, argbLength: 24 * 24 * 4 + 1),
        CursorShape(id: 1, width: 0, height: 0, hotX: 0, hotY: 0, argbLength: 4096),
    ])
    func malformedCursorShapeDeclaresNone(shape: CursorShape) throws {
        #expect(!shape.payloadFits)
        #expect(ServerMessage.cursorShape(shape).declaredPayloads == [])
        #expect(throws: Never.self) { try ServerMessage.cursorShape(shape).checkPayload(carried: 0) }
    }

    @Test func largestCursorShapeFits() {
        #expect(
            CursorShape(id: 1, width: 1024, height: 1024, hotX: 0, hotY: 0, argbLength: 1 << 22).payloadFits)
    }

    @Test func declaringFewerBytesThanCarriedIsFine() throws {
        let frame = ServerMessage.videoFrame(header(data: 1000, aux: 500))
        #expect(throws: Never.self) { try frame.checkPayload(carried: 1500) }
        #expect(throws: Never.self) { try frame.checkPayload(carried: 1600) }
    }

    @Test func declaringMoreBytesThanCarriedFails() {
        #expect(throws: ProtocolError.payloadOverrun(declared: 1500, carried: 1400)) {
            try ServerMessage.videoFrame(header(data: 1000, aux: 500)).checkPayload(carried: 1400)
        }
    }

    /// Each section is limited on its own, even when the frame as a whole is within its limit.
    @Test func eachSectionIsLimitedToMaxPayload() {
        let over = FrameHeader.maxPayload + 1
        #expect(throws: ProtocolError.payloadTooLarge(over)) {
            try ServerMessage.videoFrame(header(data: over, aux: 0)).checkPayload(carried: Int(over))
        }
        #expect(throws: ProtocolError.payloadTooLarge(over)) {
            try ServerMessage.clipboard(.data(id: 1, offset: 0, dataLength: over, done: true))
                .checkPayload(carried: Int(over))
        }
    }

    private func header(data: UInt32, aux: UInt32) -> VideoFrameHeader {
        VideoFrameHeader(
            frameID: 1, ptsMicroseconds: 0, isKeyframe: true, damage: [], dataLength: data, auxLength: aux)
    }
}
