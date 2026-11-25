import Testing

@testable import GliffTransport

/// How a sheet shows what ssh and the host wrote.
@Suite struct SignInQuestionDisplayTests {
    /// Escape codes, tabs and carriage returns go; the host's line breaks stay.
    @Test func theHostsTextKeepsOnlyLineBreaks() {
        #expect(SignInQuestion.shownHostText("a\u{1B}[31mb\r\nc\td\u{7}") == "a[31mb\ncd")
    }

    /// Bidirectional controls can make text read as something else: all go.
    @Test func theHostsTextLosesBidiControls() {
        let text =
            "\u{202A}a\u{202B}b\u{202C}c\u{202D}d\u{202E}e\u{2066}f\u{2067}g\u{2068}h\u{2069}i\u{200E}j\u{200F}k"
        #expect(SignInQuestion.shownHostText(text) == "abcdefghijk")
    }

    @Test func theHostsTextIsCutAt8KiB() {
        let shown = SignInQuestion.shownHostText(String(repeating: "é", count: 5000))
        #expect(shown.hasSuffix("…"))
        #expect(shown.dropLast().utf8.count == 8192)
        #expect(SignInQuestion.shownHostText("short") == "short")
    }

    @Test func aPassphraseNamesItsKeyFile() {
        let question = SignInQuestion.passphrase(
            host: "omarchy", text: "Enter passphrase for key '/Users/me/.ssh/id_ed25519': ")
        #expect(question.keyPath == "/Users/me/.ssh/id_ed25519")
    }

    @Test func aKeyFileIsShownCleaned() {
        let question = SignInQuestion.passphrase(
            host: "omarchy", text: "Enter passphrase for key '/a\u{202E}b\nc': ")
        #expect(question.keyPath == "/abc")
    }

    @Test func aPINOrAnotherQuestionNamesNoKeyFile() {
        #expect(
            SignInQuestion.passphrase(host: "omarchy", text: "Enter PIN for ED25519-SK key /k: ").keyPath
                == nil)
        #expect(SignInQuestion.password(host: "omarchy", account: "me@omarchy", text: "pw: ").keyPath == nil)
    }

    /// The user from ssh's USER@HOST, split at the last "@" (a host name has none), cleaned.
    @Test func aPasswordNamesItsUser() {
        let question = SignInQuestion.password(
            host: "omarchy", account: "a@b\u{202E}@192.168.1.196", text: "pw: ")
        #expect(question.user == "a@b")
    }

    @Test func anAccountWithNoUserOrAnotherQuestionHasNone() {
        #expect(SignInQuestion.password(host: "omarchy", account: "omarchy", text: "pw: ").user == nil)
        let hiddenUser = SignInQuestion.password(host: "omarchy", account: "\u{202E}@omarchy", text: "pw: ")
        #expect(hiddenUser.user == nil)
        #expect(SignInQuestion.passphrase(host: "omarchy", text: "PIN: ").user == nil)
    }

    /// The host as typed, without a user or ssh://, not the one ssh resolved (its HostName).
    @Test func theHostShownIsTheTypedHost() {
        let typed = SignInQuestion.password(
            host: "ssh://me@omarchy:2222", account: "me@192.168.1.196", text: "pw: ")
        #expect(typed.hostShown == "omarchy:2222")
        #expect(SignInQuestion.passphrase(host: "omarchy", text: "PIN: ").hostShown == "omarchy")
        #expect(SignInQuestion.confirm(host: "jump\u{202E}.example", text: "?").hostShown == "jump.example")
    }
}
