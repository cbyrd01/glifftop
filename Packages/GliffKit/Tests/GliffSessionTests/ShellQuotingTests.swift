import GliffTransport
import Testing

/// GliffTransport's quoting rule, used from other modules through a plain import.
struct ShellQuotingTests {
    @Test func shellQuotedIsPublic() {
        #expect(SSHCommand.shellQuoted("it's") == "'it'\\''s'")
    }
}
