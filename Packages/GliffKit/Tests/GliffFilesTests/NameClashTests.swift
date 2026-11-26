import Synchronization
import Testing

@testable import GliffFiles

@Suite struct NameClashTests {
    func next(_ name: String, isFolder: Bool = false, taken: Set<String>) async -> String? {
        await NameClash.nextFree(name, isFolder: isFolder) { taken.contains($0) }
    }

    @Test func twoIsAddedBeforeTheExtension() async {
        #expect(await next("report.pdf", taken: []) == "report.pdf")
        #expect(await next("report.pdf", taken: ["report.pdf"]) == "report 2.pdf")
        #expect(await next("report.pdf", taken: ["report.pdf", "report 2.pdf"]) == "report 3.pdf")
        #expect(await next("archive.tar.gz", taken: ["archive.tar.gz"]) == "archive.tar 2.gz")
        #expect(await next(".bashrc", taken: [".bashrc"]) == ".bashrc 2")
        #expect(await next("notes", taken: ["notes"]) == "notes 2")
        #expect(await next("my.photos", isFolder: true, taken: ["my.photos"]) == "my.photos 2")
    }

    @Test func countingStopsAtAThousand() async {
        let asked = Mutex(0)
        let name = await NameClash.nextFree("report.pdf", isFolder: false) { _ in
            asked.withLock { $0 += 1 }
            return true
        }
        #expect(name == nil)
        #expect(asked.withLock { $0 } == 1_000)
    }

    @Test func aLongNameStaysWithin255Bytes() async throws {
        let long = String(repeating: "\u{E9}", count: 125) + ".txt"
        #expect(long.utf8.count == 254)
        let name = try #require(await next(long, taken: [long]))
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix("\u{E9} 2.txt"))
    }

    /// A failure of the check is the caller's, passed through.
    @Test func aFailingCheckIsThrown() async {
        await #expect(throws: FilesError.timedOut) {
            try await NameClash.nextFree("a", isFolder: false) { _ throws(FilesError) in throw .timedOut }
        }
    }

    @Test func readmeAndREADMEFoldTogether() {
        #expect(NameClash.caseFolded("README") == NameClash.caseFolded("readme"))
        #expect(NameClash.caseFolded("Caf\u{E9}") == NameClash.caseFolded("cafe\u{301}"))
        #expect(NameClash.caseFolded("a") != NameClash.caseFolded("b"))
    }
}
