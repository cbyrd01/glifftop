import GliffSFTP
import GliffTestSupport
import Testing

@Suite struct SFTPFramerTests {
    typealias B = SFTPBytes

    func versionSeen() throws -> SFTPFramer {
        var framer = SFTPFramer()
        _ = try framer.feed(B.version)
        return framer
    }

    @Test func aPacketIsCutIntoTypeAndBody() throws {
        var framer = SFTPFramer()
        let packets = try framer.feed(B.version + B.packet(101, B.u32(1) + B.u32(0)))
        #expect(packets.count == 2)
        #expect(packets[0].type == 2)
        #expect(packets[1] == SFTPPacket(type: 101, body: B.u32(1) + B.u32(0)))
    }

    @Test func aSplitPacketIsReassembled() throws {
        var framer = try versionSeen()
        let bytes = B.packet(103, B.u32(7) + B.string([UInt8](repeating: 9, count: 100)))
        var packets: [SFTPPacket] = []
        for byte in bytes { packets += try framer.feed([byte]) }
        #expect(packets == [SFTPPacket(type: 103, body: Array(bytes.dropFirst(5)))])
    }

    @Test func manyPacketsInOneChunkAreAllCut() throws {
        var framer = try versionSeen()
        let one = B.packet(101, B.u32(1) + B.u32(0))
        let packets = try framer.feed(Array(repeating: one, count: 500).flatMap { $0 })
        #expect(packets.count == 500)
    }

    /// sftp-server's own maximum is 256 KiB; 1 KiB more is room for its header.
    @Test func aPacketOverTheLimitThrows() throws {
        var framer = try versionSeen()
        #expect(SFTPFramer.maxPacketLength == 256 * 1024 + 1024)
        #expect(throws: SFTPError.packetTooLong) { try framer.feed(B.u32(256 * 1024 + 1025)) }
        var atLimit = try versionSeen()
        #expect(try atLimit.feed(B.u32(256 * 1024 + 1024) + [103]).isEmpty)
    }

    /// Every packet after VERSION has a type and an id: five bytes at the least.
    @Test func aShortPacketThrows() throws {
        var framer = try versionSeen()
        #expect(throws: SFTPError.packetTooShort) { try framer.feed(B.u32(4) + [101, 0, 0, 0]) }
    }

    /// A login shell's text before the server starts reads as an absurd length.
    @Test func textBeforeVersionIsItsOwnError() {
        var framer = SFTPFramer()
        #expect(throws: SFTPError.textBeforeVersion) { try framer.feed(Array("Welcome!\n".utf8)) }
    }

    @Test func aFirstPacketOfAnotherTypeIsTextBeforeVersion() {
        var framer = SFTPFramer()
        #expect(throws: SFTPError.textBeforeVersion) {
            try framer.feed(B.packet(101, B.u32(1) + B.u32(0)))
        }
    }

    @Test func aShortFirstPacketIsTextBeforeVersion() {
        var framer = SFTPFramer()
        #expect(throws: SFTPError.textBeforeVersion) { try framer.feed(B.u32(1) + [2]) }
    }

    /// A shell's few bytes, then the end: still text before VERSION.
    @Test func bytesLeftAtTheEndBeforeVersionAreText() throws {
        var framer = SFTPFramer()
        #expect(try framer.feed(Array("ok\n".utf8)).isEmpty)
        #expect(throws: SFTPError.textBeforeVersion) { try framer.finish() }
    }

    @Test func aPacketCutShortByTheEndIsTruncated() throws {
        var framer = try versionSeen()
        _ = try framer.feed(Array(B.packet(101, B.u32(1) + B.u32(0)).dropLast()))
        #expect(throws: SFTPError.truncated) { try framer.finish() }
    }

    @Test func anEndBetweenPacketsIsClean() throws {
        var framer = try versionSeen()
        _ = try framer.feed(B.packet(101, B.u32(1) + B.u32(0)))
        try framer.finish()
    }

    @Test func anEndBeforeAnythingIsClean() throws {
        try SFTPFramer().finish()
    }

    @Test func aSecondVersionIsAnOrdinaryPacket() throws {
        var framer = try versionSeen()
        #expect(try framer.feed(B.version).map(\.type) == [2])
    }
}
