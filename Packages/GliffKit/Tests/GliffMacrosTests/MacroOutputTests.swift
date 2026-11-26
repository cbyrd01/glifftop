import Testing

@testable import GliffMacros

struct MacroOutputTests {
    let token = MacroToken.random()
    var start: [UInt8] { token.startLine }

    func trailer(_ words: String, token: MacroToken? = nil) -> [UInt8] {
        (token ?? self.token).trailerMarker + Array("\(words)\n".utf8)
    }

    func fed(_ chunks: [[UInt8]]) -> MacroOutput {
        var output = MacroOutput(token: token)
        for chunk in chunks where output.end == nil { output.feed(chunk) }
        output.finish()
        return output
    }

    @Test func bannerBeforeTheStartLineIsOutput() {
        let output = fed([Array("Welcome\n".utf8) + start + Array("hi\n".utf8) + trailer("exit 0")])
        #expect(output.sawStart)
        #expect(output.kept == Array("Welcome\nhi\n".utf8))
        #expect(output.end == .exit(0))
    }

    @Test func firstTrailerEndsTheRun() {
        let output = fed([start, trailer("timeout"), trailer("exit 0")])
        #expect(output.end == .timeout)
        #expect(output.kept.isEmpty)
    }

    /// The wrapper puts a newline before its trailer, which isn't the script's.
    @Test func theAddedNewlineIsDropped() {
        #expect(fed([start + Array("x".utf8) + trailer("exit 3")]).kept == Array("x".utf8))
        #expect(fed([start + Array("x\n".utf8) + trailer("exit 3")]).kept == Array("x\n".utf8))
        #expect(fed([start + trailer("exit 255")]).end == .exit(255))
    }

    @Test func aTrailerSplitAcrossChunksIsFound() {
        let all = Array("banner".utf8) + start + Array("abc".utf8) + trailer("exit 7")
        for cut in 1..<all.count {
            let output = fed([Array(all[..<cut]), Array(all[cut...])])
            #expect(output.end == .exit(7), "cut at \(cut)")
            #expect(output.kept == Array("bannerabc".utf8), "cut at \(cut)")
        }
    }

    @Test func anotherTokensTrailerOrAnUnknownWordIsOutput() {
        let other = trailer("exit 0", token: MacroToken.random())
        let unknown = trailer("exit x")
        let output = fed([start, other, unknown, trailer("exit 1")])
        #expect(output.kept == other + unknown)
        #expect(output.end == .exit(1))
    }

    @Test func withoutATrailerEverythingIsOutput() {
        let output = fed([Array("only a banner".utf8)])
        #expect(!output.sawStart)
        #expect(output.end == nil)
        #expect(output.kept == Array("only a banner".utf8))
        let started = fed([start, Array("partial #".utf8)])
        #expect(started.sawStart && started.kept == Array("partial #".utf8))
    }

    @Test func outputIsCutAt64KiBAndCounted() {
        let body = [UInt8](repeating: 0x61, count: MacroOutput.keptLimit + 1000)
        let output = fed([start, body, trailer("exit 0")])
        #expect(output.kept == [UInt8](repeating: 0x61, count: MacroOutput.keptLimit))
        #expect(output.dropped == 1000)
        #expect(output.end == .exit(0))
    }

    @Test func aTrailerPastTheCapIsFound() {
        let chunk = [UInt8](repeating: 0x62, count: 1000)
        let tail = trailer("exit 4")
        let output = fed(
            [start] + Array(repeating: chunk, count: 200) + [Array(tail[..<9]), Array(tail[9...])])
        #expect(output.end == .exit(4))
        #expect(output.kept.count == MacroOutput.keptLimit)
        #expect(output.dropped == 200_000 - MacroOutput.keptLimit)
    }

    @Test func fourMiBStopsTheRun() {
        var output = MacroOutput(token: token)
        output.feed(start)
        output.feed([UInt8](repeating: 0x63, count: MacroOutput.totalLimit - start.count - 1))
        #expect(output.end == nil)
        output.feed([0x63])
        #expect(output.end == .tooLarge)
    }
}
