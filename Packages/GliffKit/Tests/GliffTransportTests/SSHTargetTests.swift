import Testing

@testable import GliffTransport

/// What people type or paste into the connect field.
@Suite struct SSHTargetTests {
    @Test(arguments: [
        "omarchy", "user@omarchy", "ssh://user@omarchy:2222", "my_box", "omarchy.example.com",
        "[::1]", "user@192.168.1.20", "bücher.example",
        // A user name may hold what a host can't: a domain login, a machine account, ssh://
        // parameters.
        #"CORP\alice@omarchy"#, "svc$@omarchy", "ssh://user;fingerprint=x@omarchy",
    ])
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

    /// ssh_config's wildcards, which no host name has, and the shell characters ssh itself
    /// refuses in a host or user name.
    @Test(arguments: [
        "??", "*", "omar?hy", "user@*", "a'b", "a\"b", "a`b", "a$b", "a\\b", "a;b", "a&b", "a<b",
        "a>b", "a|b", "a(b", "a)b", "a{b", "a}b",
    ])
    func wildcardsAndShellCharactersAreRejected(text: String) {
        #expect(throws: SSHTargetError.invalidCharacter) { try SSHTarget(text) }
    }
}
