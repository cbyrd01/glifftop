import GliffSFTP
import Testing

@Suite struct SFTPPacketTypeTests {
    /// The numbers from draft-ietf-secsh-filexfer-02.
    @Test func theNumbersAreTheDrafts() {
        #expect(SFTPPacketType.initialize.rawValue == 1)
        #expect(SFTPPacketType.version.rawValue == 2)
        #expect(SFTPPacketType.readlink.rawValue == 19)
        #expect(SFTPPacketType.status.rawValue == 101)
        #expect(SFTPPacketType.attributes.rawValue == 105)
        #expect(SFTPPacketType.extended.rawValue == 200)
        #expect(SFTPPacketType.extendedReply.rawValue == 201)
    }
}
