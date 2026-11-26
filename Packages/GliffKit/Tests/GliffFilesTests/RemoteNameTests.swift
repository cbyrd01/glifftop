import Testing

@testable import GliffFiles

@Suite struct RemoteNameTests {
    @Test(arguments: [".", "..", "", "a/b", "a\u{0}b"])
    func anUnusableNameIsRefused(raw: String) {
        #expect(RemoteName(raw: Array(raw.utf8)) == nil)
    }

    @Test func aNameOver255BytesIsRefused() {
        #expect(RemoteName(raw: [UInt8](repeating: 0x61, count: 255)) != nil)
        #expect(RemoteName(raw: [UInt8](repeating: 0x61, count: 256)) == nil)
    }

    @Test func controlsBecomePictures() throws {
        let name = try #require(RemoteName(raw: Array("a\u{1}b\u{1B}c\u{7F}".utf8)))
        #expect(name.shown == "a\u{2401}b\u{241B}c\u{2421}")
        let c1 = try #require(RemoteName(raw: Array("x\u{85}y".utf8)))
        #expect(c1.shown == "x\u{FFFD}y")
    }

    @Test(arguments: ["\u{202E}", "\u{202A}", "\u{200E}", "\u{200F}", "\u{061C}", "\u{2066}", "\u{2069}"])
    func bidiControlsAreReplaced(control: String) throws {
        let name = try #require(RemoteName(raw: Array("report\(control)fdp.exe".utf8)))
        #expect(name.shown == "report\u{FFFD}fdp.exe")
    }

    /// Every format character and line or paragraph separator, as the sign-in sheets hide them.
    @Test(arguments: ["\u{200B}", "\u{2060}", "\u{FEFF}", "\u{2028}", "\u{2029}", "\u{E0041}"])
    func invisibleCharactersAreReplaced(character: String) throws {
        let name = try #require(RemoteName(raw: Array("rep\(character)ort.pdf".utf8)))
        #expect(name.shown == "rep\u{FFFD}ort.pdf")
    }

    @Test func nonUTF8ShowsReplacement() throws {
        let name = try #require(RemoteName(raw: [0x61, 0xFF, 0x62]))
        #expect(name.shown == "a\u{FFFD}b")
        #expect(name.raw == [0x61, 0xFF, 0x62])
    }

    @Test func aLocalNameIsTheShownForm() throws {
        #expect(try #require(RemoteName(raw: Array("report.pdf".utf8))).localName == "report.pdf")
        #expect(try #require(RemoteName(raw: [0x61, 0x0A])).localName == "a\u{240A}")
    }

    /// 255 bytes on the host can show as more than 255 UTF-8 bytes once replaced.
    @Test func aLocalNameIsRefusedWhenUnsafe() throws {
        let long = try #require(RemoteName(raw: [UInt8](repeating: 0xFF, count: 100)))
        #expect(long.localName == nil)
    }

    @Test func uploadNamesAreNFC() throws {
        let decomposed = "Cafe\u{301}.txt"
        let name = try #require(RemoteName(uploading: decomposed))
        #expect(name.raw == Array("Caf\u{E9}.txt".utf8))
        #expect(RemoteName(uploading: "..") == nil)
    }
}
