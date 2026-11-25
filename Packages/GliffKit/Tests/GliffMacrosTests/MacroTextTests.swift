import Testing

@testable import GliffMacros
@testable import GliffTransport

/// What the approval sheet shows is what `sh` reads: hidden characters are refused, other
/// non-ASCII is escaped for the sheet.
@Suite struct MacroTextTests {
    struct Hidden: Sendable, CustomTestStringConvertible {
        let scalar: Unicode.Scalar
        let kind: MacroText.Problem.Kind
        var testDescription: String { "U+" + String(scalar.value, radix: 16, uppercase: true) }
    }

    static let hidden: [Hidden] = [
        Hidden(scalar: "\u{0}", kind: .control), Hidden(scalar: "\u{1B}", kind: .control),
        Hidden(scalar: "\r", kind: .control), Hidden(scalar: "\u{202E}", kind: .format),
        Hidden(scalar: "\u{2066}", kind: .format), Hidden(scalar: "\u{200B}", kind: .format),
        Hidden(scalar: "\u{2028}", kind: .separator), Hidden(scalar: "\u{2029}", kind: .separator),
    ]

    @Test(arguments: hidden)
    func hiddenCharactersAreRefused(_ hidden: Hidden) {
        var script = "echo one\necho two\n"
        script.unicodeScalars.append(contentsOf: "echo ".unicodeScalars)
        script.unicodeScalars.append(hidden.scalar)
        script += "x\n"
        let problems = MacroText.refused(in: script)
        #expect(problems == [MacroText.Problem(line: 3, kind: hidden.kind, codePoint: hidden.scalar.value)])
    }

    /// A text view draws these as line breaks, so the lines after them count as it shows them.
    @Test(arguments: ["\u{2028}", "\u{2029}", "\u{85}", "\r"] as [Unicode.Scalar])
    func aBreakStartsALineForTheProblemsAfterIt(_ lineBreak: Unicode.Scalar) {
        var script = "echo a"
        script.unicodeScalars.append(lineBreak)
        script += "echo \u{202E}b\n"
        #expect(MacroText.refused(in: script).last?.line == 2)
        #expect(MacroText.refused(in: "a\r\nb\u{202E}").last?.line == 2)
    }

    @Test func newlineAndTabAreKept() {
        #expect(MacroText.refused(in: "a\tb\nc\n").isEmpty)
    }

    @Test func otherNonASCIIIsEscapedForTheSheet() {
        let shown = MacroText.escapedForApproval("echo\u{00A0}caf\u{00E9}\n\tok")
        #expect(shown.text == "echo\\u{00A0}caf\\u{00E9}\n\tok")
        #expect(shown.escapedCount == 2)
    }

    @Test func escapingKeepsAsciiAsIs() {
        let script = "a='b' \"$(c)\" `d` \\ ~\n"
        #expect(MacroText.escapedForApproval(script) == (script, 0))
    }

    /// Typed as six ASCII characters, an escape can't pass for the scalar it names.
    @Test func aTypedEscapeIsShownApartFromTheScalar() {
        let typed = MacroText.escapedForApproval("caf\\u{00E9}")
        let real = MacroText.escapedForApproval("caf\u{00E9}")
        #expect(typed.text != real.text)
        #expect(typed.text == "caf\\u{005C}u{00E9}")
        #expect(typed.escapedCount == 1)
        #expect(MacroText.escapedForApproval("a\\b \\u").text == "a\\b \\u")
    }

    /// A typed `\` before an escaped scalar would read as an escaped backslash.
    @Test func aBackslashBeforeAnEscapeIsEscaped() {
        let shown = MacroText.escapedForApproval("\\\u{00E9}")
        #expect(shown.text == "\\u{005C}\\u{00E9}")
        #expect(shown.escapedCount == 2)
        // A backslash before an escaped backslash is escaped too, however many there are.
        #expect(MacroText.escapedForApproval("\\\\u{00E9}").text == "\\u{005C}\\u{005C}u{00E9}")
        #expect(MacroText.escapedForApproval("\\\\\u{00E9}").text == "\\u{005C}\\u{005C}\\u{00E9}")
        #expect(MacroText.escapedForApproval("\\\\n").text == "\\\\n")
    }

    @Test func aDecomposedLetterShowsEachScalar() {
        let shown = MacroText.escapedForApproval("e\u{0301}")
        #expect(shown.text == "e\\u{0301}")
        #expect(shown.escapedCount == 1)
    }

    @Test func pastedLineEndsBecomeNewlines() {
        #expect(MacroText.normalisingLineEnds("a\r\nb\rc\nd") == "a\nb\nc\nd")
    }

    @Test func hiddenSetAgreesWithTheClassifier() {
        let samples: [Unicode.Scalar] = [
            "\u{0}", "\u{7}", "\t", "\n", "\r", "\u{7F}", "\u{85}", "\u{AD}", "\u{200B}", "\u{200E}",
            "\u{202E}", "\u{2028}", "\u{2029}", "\u{2066}", "\u{FEFF}", "a", " ", "\u{A0}", "\u{E9}",
        ]
        for scalar in samples {
            let classifierHides = SSHErrorClassifier.hidden.contains(scalar.properties.generalCategory)
            let expected = classifierHides && scalar != "\n" && scalar != "\t"
            #expect(
                (MacroText.refusal(of: scalar) != nil) == expected, "U+\(String(scalar.value, radix: 16))")
        }
    }
}
