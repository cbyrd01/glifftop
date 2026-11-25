import GliffSFTP
import GliffTestSupport
import Testing

@Suite struct SFTPReplyTests {
    typealias B = SFTPBytes

    func decode(_ type: UInt8, _ body: [UInt8]) throws(SFTPError) -> SFTPReply {
        try SFTPReply.decode(SFTPPacket(type: type, body: body))
    }

    @Test func versionListsTheExtensions() throws {
        var framer = SFTPFramer()
        let packet = try #require(try framer.feed(B.version).first)
        guard case .version(let extensions) = try SFTPReply.decode(packet) else {
            Issue.record("not a version")
            return
        }
        #expect(extensions.posixRename && extensions.statvfs && extensions.fsync && extensions.limits)
    }

    @Test func versionMustBeThree() {
        #expect(throws: SFTPError.unsupportedVersion) { try decode(2, B.u32(4)) }
    }

    @Test func tooManyExtensionPairsThrow() throws {
        let pair = B.string("x@example.com") + B.string("1")
        _ = try decode(2, B.u32(3) + Array(repeating: pair, count: 64).flatMap { $0 })
        #expect(throws: SFTPError.tooManyExtensions) {
            try decode(2, B.u32(3) + Array(repeating: pair, count: 65).flatMap { $0 })
        }
    }

    @Test func anExtensionOver4KiBThrows() {
        #expect(throws: SFTPError.stringTooLong) {
            try decode(2, B.u32(3) + B.string([UInt8](repeating: 0x61, count: 4097)) + B.string("1"))
        }
    }

    /// Each reply layout decoded is the one of the version OpenSSH offers.
    @Test func anExtensionAtAnotherVersionIsOff() throws {
        let offered = [
            "posix-rename@openssh.com", "statvfs@openssh.com", "fsync@openssh.com", "limits@openssh.com",
        ]
        guard
            case .version(let extensions) = try decode(
                2, B.u32(3) + offered.flatMap { B.string($0) + B.string("9") })
        else {
            Issue.record("not a version")
            return
        }
        #expect(!extensions.posixRename && !extensions.statvfs && !extensions.fsync && !extensions.limits)
    }

    @Test func spaceCanBeBuilt() {
        #expect(SFTPSpace(blockSize: 4096, fragmentSize: 512, availableBlocks: 2).availableBytes == 1024)
    }

    @Test func anUnlistedExtensionIsOff() throws {
        guard case .version(let extensions) = try decode(2, B.u32(3)) else {
            Issue.record("not a version")
            return
        }
        #expect(!extensions.posixRename && !extensions.statvfs && !extensions.fsync && !extensions.limits)
    }

    @Test func aStatusKeepsItsCodeOnly() throws {
        let reply = try decode(101, B.u32(9) + B.u32(3) + B.string("Permission denied") + B.string("en"))
        #expect(reply == .status(id: 9, code: .permissionDenied))
        #expect(reply.id == 9)
    }

    /// The message and language are optional.
    @Test func aStatusWithoutStringsDecodes() throws {
        #expect(try decode(101, B.u32(9) + B.u32(1)) == .status(id: 9, code: .endOfFile))
        #expect(try decode(101, B.u32(9) + B.u32(4) + B.string("x")) == .status(id: 9, code: .failure))
    }

    @Test(arguments: [
        (UInt32(0), SFTPStatusCode.ok), (1, .endOfFile), (2, .noSuchFile), (3, .permissionDenied),
        (4, .failure), (5, .badMessage), (6, .noConnection), (7, .connectionLost), (8, .unsupported),
        (99, .other(99)),
    ])
    func statusCodesAreTheDrafts(_ raw: UInt32, _ code: SFTPStatusCode) {
        #expect(SFTPStatusCode(raw) == code)
    }

    @Test func aHandleDataAndAttributesDecode() throws {
        #expect(try decode(102, B.u32(1) + B.string([0, 1])) == .handle(id: 1, handle: [0, 1]))
        #expect(try decode(103, B.u32(2) + B.string([5, 6, 7])) == .data(id: 2, bytes: [5, 6, 7]))
        #expect(
            try decode(105, B.u32(3) + B.u32(1) + B.u64(42)) == .attributes(id: 3, SFTPAttributes(size: 42)))
        #expect(try decode(201, B.u32(4) + [1, 2]) == .extendedReply(id: 4, body: [1, 2]))
    }

    @Test func aNameReplySkipsTheLongname() throws {
        let entry = B.string("a.txt") + B.string("-rw-r--r-- 1 person person 3 a.txt") + B.u32(1) + B.u64(3)
        let reply = try decode(104, B.u32(5) + B.u32(2) + entry + entry)
        let expected = SFTPNameEntry(name: Array("a.txt".utf8), attributes: SFTPAttributes(size: 3))
        #expect(reply == .name(id: 5, entries: [expected, expected]))
    }

    /// Each entry takes 12 bytes at the least, so a count its bytes can't hold is a lie.
    @Test func aNameCountLargerThanItsBytesThrows() {
        #expect(throws: SFTPError.nameCountTooLarge) { try decode(104, B.u32(5) + B.u32(2) + [0, 0, 0]) }
        #expect(throws: SFTPError.nameCountTooLarge) { try decode(104, B.u32(5) + B.u32(0xFFFF_FFFF)) }
    }

    @Test func aNameOver4KiBThrows() {
        let long = B.string([UInt8](repeating: 0x61, count: 4097)) + B.string("") + B.u32(0)
        #expect(throws: SFTPError.stringTooLong) { try decode(104, B.u32(5) + B.u32(1) + long) }
    }

    @Test func aDataStringPastTheEndThrows() {
        #expect(throws: SFTPError.truncated) { try decode(103, B.u32(2) + B.u32(10) + [1]) }
    }

    @Test func anUnknownReplyTypeThrows() {
        #expect(throws: SFTPError.unexpectedType(3)) { try decode(3, B.u32(1)) }
    }

    @Test func statvfsAndLimitsDecode() throws {
        let statvfs = (1...11).flatMap { B.u64(UInt64($0)) }
        let space = try SFTPSpace.decode(statvfs)
        #expect(space.blockSize == 1 && space.fragmentSize == 2 && space.availableBlocks == 5)
        #expect(space.availableBytes == 10)
        let limits = try SFTPLimits.decode(B.u64(262144) + B.u64(261120) + B.u64(261120) + B.u64(0))
        #expect(
            limits
                == SFTPLimits(packetLength: 262144, readLength: 261120, writeLength: 261120, openHandles: 0))
        #expect(throws: SFTPError.truncated) { try SFTPLimits.decode(B.u64(1)) }
    }

    /// A server that leaves the fragment size 0 counts in blocks.
    @Test func aZeroFragmentSizeCountsInBlocks() {
        #expect(SFTPSpace(blockSize: 4096, fragmentSize: 0, availableBlocks: 2).availableBytes == 8192)
    }

    /// A chunk is the server's limit, never more than a packet the framer takes, and that
    /// packet size when the server names no limit (0).
    @Test(arguments: [(UInt64(32768), UInt32(32768)), (1 << 20, 261_120), (0, 261_120)])
    func chunksStayWithinAPacket(limit: UInt64, chunk: UInt32) {
        let limits = SFTPLimits(packetLength: 0, readLength: limit, writeLength: limit, openHandles: 0)
        #expect(limits.readChunk == chunk)
        #expect(limits.writeChunk == chunk)
    }

    @Test func hugeSpaceSaturates() throws {
        let statvfs =
            [B.u64(1), B.u64(.max), B.u64(0), B.u64(0), B.u64(.max)] + (6...11).map { _ in B.u64(0) }
        #expect(try SFTPSpace.decode(statvfs.flatMap { $0 }).availableBytes == .max)
    }
}
