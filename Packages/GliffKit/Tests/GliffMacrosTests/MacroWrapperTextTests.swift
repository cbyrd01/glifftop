import Testing

@testable import GliffMacros

/// The wrapper travels on the command line through any login shell unchanged, and the command
/// line carries only three numbers the Mac computed.
@Suite struct MacroWrapperTextTests {
    @Test func wrapperHasNoQuoteNewlineOrEscapingBackslash() {
        let script = MacroWrapper.script
        #expect(!script.contains("'"))
        for pair in ["\\\\", "\\'", "\\\""] { #expect(!script.contains(pair)) }
        #expect(script.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) })
    }

    /// The prelude unsets `variables`, so the list must hold every variable the wrapper sets.
    @Test func everyWrapperVariableIsListed() throws {
        let assigned = MacroWrapper.script.matches(of: /(glifftop_\w+)=/).map { String($0.output.1) }
        #expect(Set(assigned) == Set(MacroWrapper.variables))
    }

    @Test func theWrapperSendsStderrToStdoutFirst() {
        #expect(MacroWrapper.script.hasPrefix("exec 2>&1;"))
    }

    @Test func commandLineArgumentsAreDigitsAndHex() throws {
        let token = MacroToken(hex: "0123456789abcdef0123456789abcdef")!
        let line = MacroWrapper.commandLine(length: 1234, limit: 30, token: token)
        #expect(
            line == "sh -c '\(MacroWrapper.script)' glifftop-macro 1234 30 0123456789abcdef0123456789abcdef")
    }

    @Test func aTokenIs32LowercaseHexAndNewEachTime() {
        let first = MacroToken.random()
        let second = MacroToken.random()
        #expect(MacroToken(hex: first.hex) == first)
        #expect(first != second)
    }

    @Test func aTokenNeverPrintsItself() {
        let token = MacroToken.random()
        for shown in ["\(token)", String(describing: token), String(reflecting: token)] {
            #expect(!shown.contains(token.hex))
        }
        var dumped = ""
        dump(token, to: &dumped)
        #expect(!dumped.contains(token.hex))
    }

    @Test(arguments: ["", "0123", "0123456789ABCDEF0123456789ABCDEF", "0123456789abcdef0123456789abcdeg"])
    func onlyAWellFormedTokenIsMade(_ hex: String) {
        #expect(MacroToken(hex: hex) == nil)
    }
}
