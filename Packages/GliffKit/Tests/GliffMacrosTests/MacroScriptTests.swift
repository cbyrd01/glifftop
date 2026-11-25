import Foundation
import GliffTransport
import Testing

@testable import GliffMacros

/// The text a run writes on stdin: prelude, the person's script untouched, the token line.
@Suite struct MacroScriptTests {
    static let token = MacroToken(hex: "0123456789abcdef0123456789abcdef")!

    func context(_ moment: MacroMoment = .ready) throws -> MacroContext {
        try MacroContext(
            moment: moment, reconnecting: false, screen: .named("DP-1"), output: "DP-1", headless: false)
    }

    func text(_ script: String, _ moment: MacroMoment = .ready) throws -> String {
        String(
            decoding: try MacroScript.text(for: script, context: context(moment), token: Self.token),
            as: UTF8.self)
    }

    @Test func textEndsWithTheTokenLine() throws {
        #expect(try text("echo hi").hasSuffix("\n#0123456789abcdef0123456789abcdef\n"))
    }

    @Test func theFirstLinesNameGlifftopAndUnsetTheWrapper() throws {
        let lines = try text("true").split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0].hasPrefix("# Glifftop"))
        #expect(
            lines[1] == "unset glifftop_text glifftop_token glifftop_limit glifftop_pid glifftop_status"
                + " GLIFF_MOMENT GLIFF_RECONNECT GLIFF_SCREEN GLIFF_MONITOR GLIFF_OUTPUT GLIFF_HEADLESS")
    }

    @Test func everyValueIsQuoted() throws {
        let context = MacroContext.preview(for: .ready, screen: .named("DP-1"))
        let built = String(
            decoding: try MacroScript.text(for: "true", context: context, token: Self.token), as: UTF8.self)
        let lines = built.split(separator: "\n").filter { $0.hasPrefix("export ") }
        #expect(
            lines == [
                "export GLIFF_MOMENT=ready", "export GLIFF_RECONNECT=0", "export GLIFF_SCREEN=monitor",
                "export GLIFF_MONITOR=DP-1", "export GLIFF_OUTPUT='(the screen'\\''s name)'",
                "export GLIFF_HEADLESS=0",
            ])
    }

    @Test func theLookupRunsBeforeTheScript() throws {
        let built = try text("echo hi")
        let function = try #require(built.range(of: HyprlandLookup.function))
        let call = try #require(built.range(of: "\nglifftop_find_hyprland;"))
        let script = try #require(built.range(of: "echo hi"))
        #expect(function.upperBound <= call.lowerBound && call.upperBound <= script.lowerBound)
    }

    @Test func lengthIsTheUTF8ByteCount() throws {
        let accented = try MacroScript.text(for: "printf é", context: context(), token: Self.token)
        let plain = try MacroScript.text(for: "printf e", context: context(), token: Self.token)
        #expect(accented.count == plain.count + 1)
    }

    @Test(arguments: [
        "echo \u{1B}[2J", "echo a\rb", "echo \u{202E}x", "echo \u{2028}",
        String(repeating: "#", count: MacroLimits.scriptBytes + 1),
    ])
    func refusedTextBuildsNothing(_ script: String) throws {
        #expect(throws: MacroTextError.cannotRun) {
            try MacroScript.text(for: script, context: context(), token: Self.token)
        }
    }

    /// The sheet's text is a first try's, line for line, but for the output's name, not known yet.
    @Test(arguments: MacroMoment.allCases)
    func thePreviewIsTheTextThatRuns(_ moment: MacroMoment) throws {
        let preview = MacroContext.preview(for: moment, screen: .virtual)
        let real = try MacroContext(
            moment: moment, reconnecting: false, screen: .virtual, output: "gliff-4242", headless: true)
        let lines = { (context: MacroContext) throws -> [Substring] in
            let text = try MacroScript.text(for: "echo hi", context: context, token: Self.token)
            return String(decoding: text, as: UTF8.self).split(
                separator: "\n", omittingEmptySubsequences: false)
        }
        let (shown, run) = (try lines(preview), try lines(real))
        let differing = zip(shown, run).filter { $0 != $1 }
        #expect(shown.count == run.count)
        #expect(differing.map(\.1) == (moment == .before ? [] : ["export GLIFF_OUTPUT=gliff-4242"]))
    }

    #if os(macOS)
        /// The script `sh` is given, read back by stopping the text just before it runs. The
        /// text goes on stdin, as on the host: `Process` arguments are decomposed (NFD).
        func scriptAsShReadsIt(_ script: String) throws -> [UInt8] {
            let built = try text(script)
            let run = try #require(built.range(of: "\n" + MacroScript.evalLine + "\n"))
            let probe = built[..<run.lowerBound] + "\nprintf %s \"$glifftop_script\"\n"
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            let (input, output) = (Pipe(), Pipe())
            (process.standardInput, process.standardOutput) = (input, output)
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data(probe.utf8))
            try input.fileHandleForWriting.close()
            let read = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Array(read)
        }

        @Test func scriptBytesPassThrough() throws {
            let script = """
                echo "it's" 'a "test"' \\ $(date) `id -u`
                cat <<'EOF'
                $HOME é \\n
                EOF
                printf '%s\\n' "done"
                """
            for script in [script, "echo '\n"] {
                let read = try scriptAsShReadsIt(script)
                #expect(read == Array(script.utf8))
            }
        }
    #endif
}
