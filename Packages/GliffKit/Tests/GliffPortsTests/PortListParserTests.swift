import Foundation
import GliffTransport
import Testing

@testable import GliffPorts

/// The watcher's output, read as untrusted: numbers only from `P` rows, names only for them.
@Suite struct PortListParserTests {
    static let nonce = "0123456789abcdef"

    /// A frame of `lines` under this run's nonce, as the script prints it.
    static func frame(_ lines: [String], header: String = "proc 1000 32768\t60999", nonce: String = nonce)
        -> String
    {
        (["B \(nonce) \(header)"] + lines + ["E \(nonce)"]).joined(separator: "\n") + "\n"
    }

    /// A frame of uid 1000, the default range and no sockets.
    static let emptyFrame = PortFrame(uid: 1000, ephemeral: 32768...60999, sockets: [])
    /// One line of 1 KiB, its newline included.
    static let kibLine = Array((String(repeating: "x", count: 1023) + "\n").utf8)

    /// What a parser makes of `text`, fed one byte at a time.
    static func parse(_ text: String) -> (outputs: [PortListParser.Output], parser: PortListParser) {
        var parser = PortListParser(nonce: nonce)
        var outputs: [PortListParser.Output] = []
        for byte in Array(text.utf8) { outputs += parser.feed([byte]) }
        return (outputs, parser)
    }

    static func sockets(_ text: String) -> [ListeningSocket] {
        let outputs = parse(text).outputs
        guard outputs.count == 1, case .frame(let frame) = outputs[0] else {
            Issue.record("not one frame: \(outputs)")
            return []
        }
        return frame.sockets
    }

    static func ip(_ text: String) -> IPLiteral { IPLiteral(text)! }

    @Test func ipv4AndIPv6RowsParse() {
        let sockets = Self.sockets(
            Self.frame([
                "P 0100007F:1435 1000", "P 00000000000000000000000001000000:0277 1000",
                "P 0000000000000000FFFF00000100007F:1F90 1000",
                "P 00000000000000000000000000000000:0016 1000",
            ]))
        #expect(
            sockets == [
                ListeningSocket(address: Self.ip("127.0.0.1"), port: 5173, uid: 1000),
                ListeningSocket(address: Self.ip("::1"), port: 631, uid: 1000),
                ListeningSocket(address: Self.ip("::ffff:127.0.0.1"), port: 8080, uid: 1000),
                ListeningSocket(address: Self.ip("::"), port: 22, uid: 1000),
            ])
        #expect(sockets.last?.isWildcard == true)
    }

    @Test func theHeaderGivesTheUidAndRange() {
        let outputs = Self.parse(Self.frame([], header: "proc 1000 40000 50000")).outputs
        #expect(outputs == [.frame(PortFrame(uid: 1000, ephemeral: 40000...50000, sockets: []))])
    }

    @Test func aNoneFrameIsUnavailable() {
        #expect(Self.parse("B \(Self.nonce) none\nE \(Self.nonce)\n").outputs == [.unavailable])
    }

    @Test func anotherUsersRowIsDropped() {
        let sockets = Self.sockets(Self.frame(["P 00000000:0016 0", "P 0100007F:1435 1000"]))
        #expect(sockets.map(\.port) == [5173])
    }

    @Test func malformedRowsAreDropped() {
        let sockets = Self.sockets(
            Self.frame([
                "P 0100007F:0000 1000", "P 0100007F:1435", "P 0100007F:1435 1000 x", "P 0100007:1435 1000",
                "P 0100007G:1435 1000", "P 0100007F:14351 1000", "P  0100007F:1435 1000",
            ]))
        #expect(sockets.isEmpty)
    }

    static let addressForms: [(String, String)] = [
        ("127.0.0.1:5173", "0100007F:1435"),
        ("0.0.0.0:5173", "00000000:1435"),
        ("*:5173", "00000000:1435"),
        ("*:5173", "00000000000000000000000000000000:1435"),
        ("[::]:5173", "00000000000000000000000000000000:1435"),
        ("[::1]:5173", "00000000000000000000000001000000:1435"),
        ("[::ffff:127.0.0.1]:5173", "0000000000000000FFFF00000100007F:1435"),
    ]

    @Test(arguments: addressForms) func eachSSAddressFormNamesItsSocket(_ form: String, _ row: String) {
        let sockets = Self.sockets(
            Self.frame([
                "P \(row) 1000", "N LISTEN   \(form) 0.0.0.0:* users:((\"node\",pid=4242,fd=21))",
            ]))
        #expect(sockets.map(\.name) == ["node"])
    }

    @Test func aZonedAddressIsDropped() {
        let sockets = Self.sockets(
            Self.frame([
                "P 000080FE000000000000000001000000:1435 1000",
                "N LISTEN   [fe80::1%eth0]:5173 [::]:* users:((\"node\",pid=4242,fd=21))",
            ]))
        #expect(sockets.map(\.name) == [nil])
    }

    @Test func aNameLineNeverAddsAPort() {
        let sockets = Self.sockets(
            Self.frame(["N LISTEN   127.0.0.1:9 0.0.0.0:* users:((\"node\",pid=4242,fd=21))"]))
        #expect(sockets.isEmpty)
    }

    /// A process name with a newline in it makes a line of its own: at worst it names a port
    /// the kernel listed.
    @Test func aFakedLineCanOnlyMisnameARealPort() {
        let sockets = Self.sockets(
            Self.frame([
                "P 0100007F:1435 1000",
                "N LISTEN   127.0.0.1:5173 0.0.0.0:* users:((\"fake\",pid=1,fd=3))",
                "N LISTEN   0.0.0.0:9 0.0.0.0:* users:((\"x\",pid=1,fd=3))",
                "N LISTEN   127.0.0.1:5173 0.0.0.0:* users:((\"node\",pid=4242,fd=21))",
            ]))
        #expect(
            sockets == [ListeningSocket(address: Self.ip("127.0.0.1"), port: 5173, uid: 1000, name: "fake")])
    }

    @Test func aNameNeedsItsShape() {
        let sockets = Self.sockets(
            Self.frame([
                "P 0100007F:1435 1000",
                "N ESTAB   127.0.0.1:5173 0.0.0.0:* users:((\"a\",pid=1,fd=3))",
                "N LISTEN   127.0.0.1:5173 0.0.0.0:* (\"b\",pid=1,fd=3)",
                "N LISTEN   127.0.0.1:5173 0.0.0.0:* users:((\"c\")",
            ]))
        #expect(sockets.map(\.name) == [nil])
    }

    @Test func namesAreCleanedAndCut() {
        let long = String(repeating: "x", count: 40)
        let sockets = Self.sockets(
            Self.frame([
                "P 0100007F:1435 1000",
                "N LISTEN   127.0.0.1:5173 0.0.0.0:* users:((\"a\u{202E}b\u{1}c\u{2066}\(long)\",pid=1,fd=3))",
            ]))
        #expect(sockets.first?.name == "abc" + String(repeating: "x", count: 29))
    }

    /// Only ASCII hex digits make an address; a field with others is dropped, not shortened.
    @Test func aRowWithNonASCIIDigitsIsDropped() {
        let fullwidth = String(repeating: "\u{FF10}", count: 24)
        #expect(Self.sockets(Self.frame(["P \(fullwidth)0100007F:1435 1000"])).isEmpty)
        #expect(Self.sockets(Self.frame(["P 0100007F:\u{FF11}435 1000"])).isEmpty)
    }

    /// A frame cut short by the next frame's header is counted as dropped.
    @Test func aFrameWithoutItsEndIsCounted() {
        let parsed = Self.parse("B \(Self.nonce) proc 1000\nP 0100007F:1435 1000\n" + Self.frame([]))
        #expect(parsed.outputs.count == 1)
        #expect(parsed.parser.droppedFrames == 1)
    }

    /// The most the script prints in a frame: every `P` line at its longest (IPv6, a 10-digit
    /// uid) and every `N` line at its cut.
    @Test func theLargestFrameTheScriptPrintsIsRead() {
        let uid = 4_294_967_294
        let row = "P " + String(repeating: "0", count: 32) + ":1435 \(uid)"
        let name = "N " + String(repeating: "x", count: PortWatchCommand.maxNameLine)
        let lines =
            Array(repeating: row, count: PortWatchCommand.maxLines)
            + Array(repeating: name, count: PortWatchCommand.maxLines)
        let outputs = Self.parse(Self.frame(lines, header: "proc \(uid) 32768 60999")).outputs
        #expect(outputs.count == 1)
    }

    /// 600 lines is the most a frame has, its B and E lines among them.
    @Test func sixHundredLinesIsTheMostAFrameHas() {
        let body = Array(repeating: "P 0100007F:1435 1000", count: 598)
        #expect(Self.parse(Self.frame(body)).outputs.count == 1)
        let parsed = Self.parse(Self.frame(body + ["P 0100007F:1436 1000"]))
        #expect(parsed.outputs.isEmpty)
        #expect(parsed.parser.droppedFrames == 1)
    }

    /// A header without its uid (an empty `$u`) is no frame.
    @Test func aHeaderMissingItsUidIsNoFrame() {
        #expect(
            Self.parse(Self.frame(["P 0100007F:1435 32768"], header: "proc 32768\t60999")).outputs.isEmpty)
    }

    /// A frame cut off by the next one doesn't count toward the next one's overflow.
    @Test func aCutOffFrameDoesNotOverflowTheNext() {
        var parser = PortListParser(nonce: Self.nonce)
        var outputs = parser.feed(Array("B \(Self.nonce) proc 1000\n".utf8))
        for _ in 0..<100 { outputs += parser.feed(Self.kibLine) }
        outputs += parser.feed(
            Array(Self.frame(Array(repeating: "N " + String(repeating: "x", count: 100), count: 400)).utf8))
        #expect(outputs == [.frame(Self.emptyFrame)])
    }

    @Test func aWrongNonceIsIgnored() {
        let parsed = Self.parse(Self.frame(["P 0100007F:1435 1000"], nonce: "fedcba9876543210"))
        #expect(parsed.outputs.isEmpty)
    }

    @Test func aFrameOverACapIsDroppedAndCounted() {
        let tooBig = [String(repeating: "x", count: 65 * 1024)]
        let parsed = Self.parse(Self.frame(tooBig) + Self.frame([]))
        #expect(parsed.outputs == [.frame(Self.emptyFrame)])
        #expect(parsed.parser.droppedFrames == 1)
    }

    @Test func unframedOutputPast128KiBOverflows() {
        var parser = PortListParser(nonce: Self.nonce)
        let line = Self.kibLine
        var outputs: [PortListParser.Output] = []
        for _ in 0..<129 { outputs += parser.feed(line) }
        #expect(outputs == [.overflow])
        #expect(parser.feed(Array(Self.frame([]).utf8)).isEmpty)
    }

    @Test func aLongFrameEndingInTimeIsRead() {
        var parser = PortListParser(nonce: Self.nonce)
        let filler = Self.kibLine
        for _ in 0..<100 { #expect(parser.feed(filler).isEmpty) }
        #expect(parser.feed(Array(Self.frame([]).utf8)).count == 1)
        for _ in 0..<100 { #expect(parser.feed(filler).isEmpty) }
        #expect(parser.feed(Array(Self.frame([]).utf8)).count == 1)
    }

    @Test(arguments: [
        "proc 1000", "proc 1000 60999 32768", "proc 1000 0 10", "proc 1000 a b", "proc 1000 1 2 3",
    ])
    func aBadRangeHeaderFallsBack(_ header: String) {
        let outputs = Self.parse(Self.frame([], header: header)).outputs
        #expect(outputs == [.frame(Self.emptyFrame)])
    }

    @Test func aBadHeaderIsNoFrame() {
        #expect(Self.parse(Self.frame([], header: "proc x")).outputs.isEmpty)
        #expect(Self.parse(Self.frame([], header: "list 1000")).outputs.isEmpty)
    }

    @Test func textBeforeTheFirstFrameIsCounted() {
        let parsed = Self.parse("hello\n" + Self.frame([]) + "later\n")
        #expect(parsed.outputs.count == 1)
        #expect(parsed.parser.bytesBeforeFirstFrame == 6)
    }

    @Test func sixtyFourSocketsAreKeptAfterTheUidFilter() {
        let others = (1...10).map { String(format: "P 0100007F:%04X 0", $0) }
        let own = (1...70).map { String(format: "P 0100007F:%04X 1000", $0 + 100) }
        let sockets = Self.sockets(Self.frame(others + own))
        #expect(sockets.count == 64)
        #expect(sockets.allSatisfy { $0.uid == 1000 })
        #expect(sockets.first?.port == 101)
    }

    @Test func aFrameCutAtSixtyFourSaysSo() throws {
        let own = { (count: Int) in (1...count).map { String(format: "P 0100007F:%04X 1000", $0 + 100) } }
        let frame = { (lines: [String]) -> PortFrame? in
            guard case .frame(let frame) = Self.parse(Self.frame(lines)).outputs.first else { return nil }
            return frame
        }
        #expect(try #require(frame(own(64))).isComplete)
        #expect(try #require(frame(own(64) + own(1))).isComplete)
        #expect(try #require(frame(own(65))).isComplete == false)
    }
}
