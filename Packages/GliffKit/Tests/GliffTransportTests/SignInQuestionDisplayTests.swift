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
}
