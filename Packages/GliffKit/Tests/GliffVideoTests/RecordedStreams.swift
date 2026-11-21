import Foundation

/// The `.gliffrec` recordings `RecordedStreamTests` decodes, as Debug ▸ Record 5 Seconds writes
/// them:
/// - `Fixtures/recorded/` in the bundle: committed recordings. Only captures the maintainer has
///   approved go there: each needs its line in `captures.sha256`, added by the maintainer's
///   `scripts/approve-capture.sh`, and the pre-commit hook refuses any other file there (a README
///   too, so this comment is that folder's documentation). A recording shows whatever was on
///   the screen, so record a clean, prepared desktop.
/// - `<repo>/.recordings/`: local recordings, which never leave the machine. Each is a test
///   case in the gate, so a cut-off or broken recording there fails it: delete or move it.
enum RecordedStreams {
    static let all: [URL] = {
        let bundled =
            Bundle.module.urls(forResourcesWithExtension: "gliffrec", subdirectory: "Fixtures/recorded") ?? []
        // <repo>/Packages/GliffKit/Tests/GliffVideoTests/<this file>: the repo is five levels up.
        var repo = URL(filePath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let local = repo.appending(path: ".recordings", directoryHint: .isDirectory)
        let localFiles =
            (try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)) ?? []
        return (bundled + localFiles.filter { $0.pathExtension == "gliffrec" })
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()
}
