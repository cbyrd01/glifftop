import Foundation

/// A new folder for one test, removed by `remove()`.
struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "GliffFiles-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    /// Writes `text` to a new file `name` in the folder.
    func file(_ name: String, _ text: String = "") throws -> URL {
        let file = url.appending(path: name)
        try Data(text.utf8).write(to: file)
        return file
    }

    /// An item's status, never following a link.
    static func status(_ url: URL) -> stat {
        var status = stat()
        lstat(url.path(percentEncoded: false), &status)
        return status
    }
}
