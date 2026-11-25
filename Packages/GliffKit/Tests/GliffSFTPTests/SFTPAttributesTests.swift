import GliffSFTP
import Testing

@Suite struct SFTPAttributesTests {
    typealias B = SFTPBytes

    @Test func everyFieldIsRead() throws {
        var reader = SFTPReader(
            B.u32(0xF) + B.u64(12) + B.u32(1000) + B.u32(100) + B.u32(0o100644) + B.u32(5) + B.u32(6))
        let attributes = try SFTPAttributes(from: &reader)
        #expect(attributes.size == 12)
        #expect(attributes.uid == 1000 && attributes.gid == 100)
        #expect(attributes.permissions == 0o100644)
        #expect(attributes.times == SFTPTimes(access: 5, modification: 6))
        #expect(reader.isAtEnd)
    }

    @Test func noFlagsIsNoFields() throws {
        var reader = SFTPReader(B.u32(0))
        #expect(try SFTPAttributes(from: &reader) == SFTPAttributes())
    }

    /// v3 attributes carry no length, so a flag the reader can't size ends the session.
    @Test func unknownAttributeFlagsThrow() {
        var reader = SFTPReader(B.u32(0x10))
        #expect(throws: SFTPError.unknownAttributeFlags) { try SFTPAttributes(from: &reader) }
    }

    @Test func extendedPairsAreReadAndSkipped() throws {
        var reader = SFTPReader(
            B.u32(0x8000_0004) + B.u32(0o40755) + B.u32(2) + B.string("a") + B.string("b") + B.string("c")
                + B.string("d") + [9])
        let attributes = try SFTPAttributes(from: &reader)
        #expect(attributes.permissions == 0o40755)
        #expect(reader.remaining == 1)
    }

    @Test func extendedPairsPastTheEndThrow() {
        var reader = SFTPReader(B.u32(0x8000_0000) + B.u32(2) + B.string("a"))
        #expect(throws: SFTPError.truncated) { try SFTPAttributes(from: &reader) }
    }

    @Test func tooManyExtendedPairsThrow() {
        var reader = SFTPReader(B.u32(0x8000_0000) + B.u32(65))
        #expect(throws: SFTPError.tooManyExtensions) { try SFTPAttributes(from: &reader) }
    }

    @Test(arguments: [
        (UInt32(0o100644), SFTPFileType.regular), (0o040755, .directory), (0o120777, .link),
        (0o010644, .fifo), (0o140755, .socket), (0o020660, .device), (0o060660, .device), (0o644, .unknown),
    ])
    func theFileTypeComesFromTheModeBits(_ mode: UInt32, _ type: SFTPFileType) {
        #expect(SFTPAttributes(permissions: mode).fileType == type)
    }

    @Test func noPermissionsIsNoFileType() {
        #expect(SFTPAttributes(size: 3).fileType == nil)
    }

    /// The writer never sends an owner, even one read from the host: Glifftop never sets one.
    @Test func encodingNeverCarriesOwnership() throws {
        var reader = SFTPReader(
            B.u32(0xF) + B.u64(1) + B.u32(0) + B.u32(0) + B.u32(0o600) + B.u32(2) + B.u32(3))
        let attributes = try SFTPAttributes(from: &reader)
        #expect(attributes.uid == 0)
        var writer = SFTPWriter()
        attributes.write(to: &writer)
        #expect(writer.bytes == B.u32(0xD) + B.u64(1) + B.u32(0o600) + B.u32(2) + B.u32(3))
    }

    @Test func emptyAttributesAreAZeroFlagsWord() {
        var writer = SFTPWriter()
        SFTPAttributes().write(to: &writer)
        #expect(writer.bytes == B.u32(0))
    }
}
