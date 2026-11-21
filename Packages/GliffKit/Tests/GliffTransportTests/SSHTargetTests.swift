import Testing

@testable import GliffTransport

/// What people type or paste into the connect field.
@Suite struct SSHTargetTests {
    @Test(arguments: ["omarchy", "user@omarchy", "ssh://user@omarchy:2222"])
    func acceptedUnchanged(text: String) throws {
        #expect(try SSHTarget(text).value == text)
    }

    @Test func surroundingWhitespaceIsTrimmed() throws {
        #expect(try SSHTarget("  omarchy \n").value == "omarchy")
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func emptyIsRejected(text: String) {
        #expect(throws: SSHTargetError.empty) { try SSHTarget(text) }
    }

    /// A pasted option would be read by ssh as an option, not a host.
    /// `-` plus a combining mark is one Character but still starts with the byte `-`.
    @Test(arguments: ["-oProxyCommand=touch /tmp/x", " -p2222 omarchy", "-\u{301}oProxyCommand=x"])
    func leadingDashIsRejected(text: String) {
        #expect(throws: SSHTargetError.startsWithDash) { try SSHTarget(text) }
    }

    /// The user or host part reaches ProxyCommand's %r/%h unprotected by `--`.
    @Test(arguments: ["user@-oProxyCommand=x", "ssh://-oFoo", "SSH://user@-x:22", "ssh://-u@omarchy"])
    func dashAfterSchemeOrAtIsRejected(text: String) {
        #expect(throws: SSHTargetError.startsWithDash) { try SSHTarget(text) }
    }

    @Test(arguments: ["a b", "a\tb", "a\u{7}b", "a\nb", "a\u{0}b", "a\u{2028}b"])
    func innerWhitespaceOrControlIsRejected(text: String) {
        #expect(throws: SSHTargetError.containsWhitespaceOrControl) { try SSHTarget(text) }
    }
}
