import GliffAskpass
import Testing

struct AskpassWireTests {
    static let token = [UInt8](repeating: 7, count: 32)

    @Test func aRequestRoundTrips() throws {
        let request = AskpassRequest(token: Self.token, kind: .ask, text: "person@omarchy's password: ")
        #expect(try AskpassRequest.decode(request.encoded()) == request)
    }

    @Test func aNoticeRoundTrips() throws {
        let request = AskpassRequest(token: Self.token, kind: .notice, text: "Confirm user presence")
        #expect(try AskpassRequest.decode(request.encoded()) == request)
    }

    @Test func theHeaderGivesTheTextsLength() throws {
        let bytes = AskpassRequest(token: Self.token, kind: .ask, text: "héllo").encoded()
        #expect(try AskpassRequest.textLength(header: Array(bytes.prefix(AskpassRequest.headerLength))) == 6)
    }

    @Test func aTextOverTheLimitIsRefused() {
        var bytes = AskpassRequest(token: Self.token, kind: .ask, text: "").encoded()
        bytes.replaceSubrange(34..<38, with: [0, 0, 0x20, 0x01])  // 8193
        bytes += [UInt8](repeating: 65, count: 8193)
        #expect(throws: AskpassWire.Error.tooLong) { try AskpassRequest.decode(bytes) }
    }

    @Test func anotherVersionIsRefused() {
        var bytes = AskpassRequest(token: Self.token, kind: .ask, text: "x").encoded()
        bytes[0] = 2
        #expect(throws: AskpassWire.Error.version) { try AskpassRequest.decode(bytes) }
    }

    @Test func anUnknownKindIsRefused() {
        var bytes = AskpassRequest(token: Self.token, kind: .ask, text: "x").encoded()
        bytes[1] = 9
        #expect(throws: AskpassWire.Error.malformed) { try AskpassRequest.decode(bytes) }
    }

    @Test func aShortFrameIsRefused() {
        let bytes = AskpassRequest(token: Self.token, kind: .ask, text: "hello").encoded()
        #expect(throws: AskpassWire.Error.short) { try AskpassRequest.decode(Array(bytes.dropLast())) }
        #expect(throws: AskpassWire.Error.short) { try AskpassRequest.decode(Array(bytes.prefix(10))) }
    }

    @Test func aReplyHeaderRoundTrips() throws {
        let header = try AskpassReply.header(.answer, length: 1024)
        #expect(header.count == AskpassReply.headerLength)
        let decoded = try AskpassReply.decodeHeader(header)
        #expect(decoded.status == .answer && decoded.length == 1024)
    }

    @Test func anAnswerOverOneKiBIsRefused() throws {
        var header = try AskpassReply.header(.answer, length: 0)
        header[2...3] = [0x04, 0x01]  // 1025
        #expect(throws: AskpassWire.Error.tooLong) { try AskpassReply.decodeHeader(header) }
    }

    @Test func anAnswerOverOneKiBHasNoHeader() {
        #expect(throws: AskpassWire.Error.tooLong) { try AskpassReply.header(.answer, length: 1025) }
        #expect(throws: AskpassWire.Error.malformed) { try AskpassReply.header(.refuse, length: 1) }
    }

    @Test func aRefusalCarriesNoBytes() throws {
        var header = try AskpassReply.header(.refuse, length: 0)
        #expect(try AskpassReply.decodeHeader(header).status == .refuse)
        header[3] = 1
        #expect(throws: AskpassWire.Error.malformed) { try AskpassReply.decodeHeader(header) }
    }
}
