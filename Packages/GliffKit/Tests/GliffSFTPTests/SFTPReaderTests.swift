import GliffSFTP
import GliffTestSupport
import Testing

@Suite struct SFTPReaderTests {
    typealias B = SFTPBytes

    @Test func integersAreBigEndian() throws {
        var reader = SFTPReader([7] + B.u32(0x0102_0304) + B.u64(0x0102_0304_0506_0708))
        #expect(try reader.byte() == 7)
        #expect(try reader.uint32() == 0x0102_0304)
        #expect(try reader.uint64() == 0x0102_0304_0506_0708)
        #expect(reader.isAtEnd)
    }

    @Test func aStringIsItsLengthThenItsBytes() throws {
        var reader = SFTPReader(B.string([0xFF, 0, 0x2F]))
        #expect(try reader.string(max: 16) == [0xFF, 0, 0x2F])
        #expect(reader.isAtEnd)
    }

    @Test func aStringPastTheEndThrows() {
        var reader = SFTPReader(B.u32(10) + [1, 2, 3])
        #expect(throws: SFTPError.truncated) { try reader.string(max: 4096) }
    }

    @Test func aStringOverItsLimitThrows() {
        var reader = SFTPReader(B.string([UInt8](repeating: 1, count: 17)))
        #expect(throws: SFTPError.stringTooLong) { try reader.string(max: 16) }
    }

    @Test func anIntegerPastTheEndThrows() {
        var reader = SFTPReader([0, 0, 1])
        #expect(throws: SFTPError.truncated) { try reader.uint32() }
        var short = SFTPReader(B.u32(1))
        #expect(throws: SFTPError.truncated) { try short.uint64() }
    }

    @Test func aStringCanBeSkipped() throws {
        var reader = SFTPReader(B.string("longname") + B.u32(5))
        try reader.skipString(max: 4096)
        #expect(try reader.uint32() == 5)
    }

    @Test func theRestIsWhatIsLeft() throws {
        var reader = SFTPReader(B.u32(1) + [9, 8])
        _ = try reader.uint32()
        #expect(reader.remaining == 2)
        #expect(reader.rest() == [9, 8])
        #expect(reader.isAtEnd)
    }
}

@Suite struct SFTPWriterTests {
    typealias B = SFTPBytes

    @Test func integersAndStringsAreWrittenAsTheDraftSays() {
        var writer = SFTPWriter()
        writer.byte(3)
        writer.uint32(0x0A0B_0C0D)
        writer.uint64(1)
        writer.string([1, 2])
        writer.string("ab")
        #expect(writer.bytes == [3] + B.u32(0x0A0B_0C0D) + B.u64(1) + B.string([1, 2]) + B.string("ab"))
    }

    @Test func aPacketGetsItsLength() {
        var writer = SFTPWriter()
        writer.byte(1)
        writer.uint32(3)
        #expect(writer.packet() == B.u32(5) + [1] + B.u32(3))
    }
}
