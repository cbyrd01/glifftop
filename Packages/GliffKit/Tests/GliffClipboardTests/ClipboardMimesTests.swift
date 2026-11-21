import GliffClipboard
import Testing

@Suite struct ClipboardMimesTests {
    @Test func textFlavoursCollapseToAllFive() {
        #expect(
            ClipboardMimes.forwardable(["STRING", "text/html"])
                == ClipboardMimes.textFlavours + ["text/html"])
    }

    @Test func theFiveAreUpstreamsInOrder() {
        #expect(
            ClipboardMimes.textFlavours == [
                "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT",
            ])
        #expect(ClipboardMimes.text == "text/plain;charset=utf-8")
    }

    @Test func fileListsAndNonDataTargetsAreDropped() {
        let offered = [
            "text/uri-list", "x-special/gnome-copied-files", "TARGETS", "TIMESTAMP", "MULTIPLE",
            "SAVE_TARGETS", "DELETE", "INSERT_PROPERTY", "INSERT_SELECTION", "a b", "", "  ",
            "image/png",
        ]
        #expect(ClipboardMimes.forwardable(offered) == ["image/png"])
    }

    @Test func surroundingSpaceIsTrimmed() {
        #expect(ClipboardMimes.forwardable([" image/png "]) == ["image/png"])
    }

    @Test func duplicatesOnce() {
        #expect(
            ClipboardMimes.forwardable(["image/png", "text/html", "image/png", "TEXT", "STRING"])
                == ClipboardMimes.textFlavours + ["image/png", "text/html"])
    }

    @Test func resolveFindsAnyTextFlavour() {
        #expect(ClipboardMimes.resolve("text/plain;charset=utf-8", in: ["UTF8_STRING"]) == "UTF8_STRING")
        #expect(ClipboardMimes.resolve("STRING", in: ["TEXT", "text/plain"]) == "text/plain")
    }

    @Test func resolvePrefersTheExactType() {
        #expect(ClipboardMimes.resolve("STRING", in: ["text/plain", "STRING"]) == "STRING")
    }

    @Test func resolveAnswersWithTheOfferedSpelling() {
        let offered = "x/caf\u{e9}"
        let resolved = ClipboardMimes.resolve("x/cafe\u{301}", in: [offered])
        #expect(resolved.map { Array($0.utf8) } == Array(offered.utf8))
    }

    @Test func resolveRefusesWhatWasntOffered() {
        #expect(ClipboardMimes.resolve("image/png", in: ["text/html"]) == nil)
        #expect(ClipboardMimes.resolve("text/html", in: ["text/plain"]) == nil)
    }

    @Test func textAndFileMimes() {
        #expect(ClipboardMimes.isText("UTF8_STRING"))
        #expect(!ClipboardMimes.isText("text/html"))
        #expect(ClipboardMimes.isFile("text/uri-list"))
        #expect(ClipboardMimes.isFile("x-special/gnome-copied-files"))
        #expect(!ClipboardMimes.isFile("text/plain"))
        #expect(ClipboardMimes.passwordHint == "x-kde-passwordManagerHint")
    }
}
