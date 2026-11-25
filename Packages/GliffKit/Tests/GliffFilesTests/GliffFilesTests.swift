import GliffFiles
import Testing

@Suite struct GliffFilesTests {
    @Test func theSubsystemIsSFTP() {
        #expect(SFTPSubsystem.name == "sftp")
    }
}
