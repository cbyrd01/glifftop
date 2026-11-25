import GliffSFTP
import GliffTransport
import Testing

@testable import GliffFiles

@Suite struct FilesErrorTests {
    /// Only a link that went away is a lost connection; ssh's other failures (a refused
    /// subsystem, a refused channel) end the file server.
    @Test func onlyALostLinkIsALostConnection() {
        #expect(
            FilesError(transport: .exited(status: 255, failure: .sharedConnectionLost)) == .connectionLost)
        #expect(FilesError(transport: .exited(status: 255, failure: .unreachable)) == .connectionLost)
        #expect(
            FilesError(transport: .exited(status: 255, failure: .other("subsystem request failed"))) == .ended
        )
        #expect(FilesError(transport: .exited(status: 255, failure: .channelRefused)) == .ended)
        #expect(FilesError(transport: .exited(status: 1, failure: .other(""))) == .ended)
        #expect(FilesError(transport: .exited(status: 255, failure: .signInCancelled)) == .connectionLost)
        #expect(FilesError(transport: .exited(status: 255, failure: .hostKeyDenied)) == .connectionLost)
        #expect(FilesError(transport: .cancelled) == .cancelled)
    }

    /// A host that says its own link is gone has lost the connection; it didn't refuse.
    @Test func aStatusOfALostLinkIsALostConnection() {
        #expect(FilesError(status: .noConnection) == .connectionLost)
        #expect(FilesError(status: .connectionLost) == .connectionLost)
        #expect(FilesError(status: .failure) == .failure)
    }
}
