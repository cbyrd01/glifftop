import Foundation
import GliffTestSupport
import Testing

@testable import GliffFiles

@Suite struct HostFoldersCommandTests {
    static func path(_ text: String) -> RemotePath { RemotePath(absolute: Array(text.utf8))! }

    @Test func theScriptIsOneLineWithoutQuoteOrBang() {
        let script = HostFoldersCommand.script
        #expect(!script.contains("'") && !script.contains("!") && !script.contains("\n"))
    }

    @Test func theCommandRunsTheScriptUnderSh() {
        #expect(HostFoldersCommand.remoteCommand == "sh -c '\(HostFoldersCommand.script)'")
    }

    /// A command that stops mid-output, as a login shell waiting on something does, gives up.
    @Test func aStalledCommandGivesNoOutput() async throws {
        let stalled = PeerTransport {
            let peer = ScriptedSFTPPeer(version: nil)
            peer.send(Array("HOME\t/home/person\u{0}".utf8))
            return peer
        }
        let reading = Task { await HostFoldersCommand.output(of: stalled, limit: .milliseconds(50)) }
        #expect(try await reading.valueWithin() == nil)
    }

    @Test func eachKeyIsRead() {
        let output =
            "DOWNLOAD\t/home/person/Downloads\u{0}DESKTOP\t/home/person/Desktop\u{0}DOCUMENTS\t/home/person/Documents\u{0}HOME\t/home/person\u{0}"
        #expect(
            HostFoldersCommand.parse(Array(output.utf8))
                == HostFolders(
                    home: Self.path("/home/person"), downloads: Self.path("/home/person/Downloads"),
                    desktop: Self.path("/home/person/Desktop"), documents: Self.path("/home/person/Documents")
                ))
    }

    /// An answer equal to HOME, however written, is `xdg-user-dir`'s for a folder not set.
    @Test func aDownloadEqualToHomeFallsBack() throws {
        let output =
            "HOME\t/home/person\u{0}HOME_DOWNLOADS\t/home/person/Downloads\u{0}DOWNLOAD\t/home/person/\u{0}"
        let folders = try #require(HostFoldersCommand.parse(Array(output.utf8)))
        #expect(folders.downloads == Self.path("/home/person/Downloads"))
    }

    @Test func aDesktopEqualToHomeIsDropped() throws {
        let output = "DOWNLOAD\t/home/person\u{0}DESKTOP\t/home/person/\u{0}HOME\t/home/person\u{0}"
        let folders = try #require(HostFoldersCommand.parse(Array(output.utf8)))
        #expect(folders.desktop == nil)
        #expect(folders.downloads == Self.path("/home/person"))
    }

    @Test func aRelativePathIsDropped() throws {
        let output = "DOWNLOAD\tDownloads\u{0}DOCUMENTS\t/home/../etc\u{0}HOME\t/home/person\u{0}"
        let folders = try #require(HostFoldersCommand.parse(Array(output.utf8)))
        #expect(folders.downloads == Self.path("/home/person"))
        #expect(folders.documents == nil)
        #expect(HostFoldersCommand.parse(Array("HOME\tperson\u{0}".utf8)) == nil)
    }

    @Test func outputPast16KiBIsCut() {
        let filler = String(repeating: "x", count: 16 * 1024 - 10) + "\u{0}"
        #expect(HostFoldersCommand.parse(Array((filler + "HOME\t/home/person\u{0}").utf8)) == nil)
        #expect(HostFoldersCommand.parse(Array("HOME\t/home/person".utf8)) == nil)
    }

    // MARK: The script, run by /bin/sh

    /// Runs the script with `HOME` set to a new folder and `PATH` holding a stub
    /// `xdg-user-dir` that prints `answers[key]`, or `$HOME` for a key not set, as the real one
    /// does; with `answers` nil there is no `xdg-user-dir`.
    func run(answers: [String: String]?, folders: [String]) throws -> (HostFolders?, home: String) {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let base = temporary.url
        let home = base.appending(path: "home")
        let bin = base.appending(path: "bin")
        for folder in [home, bin] + folders.map({ home.appending(path: $0) }) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if let answers {
            let cases = answers.map { "\($0.key)) echo \"\($0.value)\" ;;" }.joined(separator: " ")
            let stub = bin.appending(path: "xdg-user-dir")
            try "#!/bin/sh\ncase \"$1\" in \(cases) *) echo \"$HOME\" ;; esac\n"
                .write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", HostFoldersCommand.script]
        let homePath = home.path(percentEncoded: false).replacing(/\/$/, with: "")
        process.environment = ["HOME": homePath, "PATH": bin.path(percentEncoded: false) + ":/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (HostFoldersCommand.parse(Array(output)), homePath)
    }

    @Test func theFoldersScriptFallsBackToHomeDownloads() throws {
        let (folders, home) = try run(answers: ["DOWNLOAD": "/nonexistent"], folders: ["Downloads"])
        #expect(folders?.downloads == Self.path(home + "/Downloads"))
        #expect(folders?.home == Self.path(home))
    }

    /// `xdg-user-dir` answers `$HOME` for a folder not set.
    @Test func anUnsetDownloadFallsBackToHomeDownloads() throws {
        let (folders, home) = try run(answers: [:], folders: ["Downloads"])
        #expect(folders?.downloads == Self.path(home + "/Downloads"))
        #expect(folders?.desktop == nil && folders?.documents == nil)
    }

    @Test func withoutXDGTheScriptFallsBack() throws {
        let (folders, home) = try run(answers: nil, folders: ["Downloads", "Desktop"])
        #expect(folders?.downloads == Self.path(home + "/Downloads"))
        #expect(folders?.desktop == nil)
    }

    /// Each record ends in NUL, so a folder name holding a newline is kept whole and can't
    /// supply another key.
    @Test func aNewlineInAFolderNameIsKeptWhole() throws {
        let folder = "x\nHOME\t/etc\nDESKTOP\t/etc"
        let (folders, home) = try run(answers: ["DOWNLOAD": "$HOME/\(folder)"], folders: [folder])
        #expect(folders?.home == Self.path(home))
        #expect(folders?.downloads == Self.path(home + "/" + folder))
        #expect(folders?.desktop == nil)
    }

    @Test func theFoldersScriptFallsBackToHome() throws {
        let (folders, home) = try run(answers: [:], folders: [])
        #expect(folders?.downloads == Self.path(home))
        #expect(folders?.desktop == nil)
    }

    @Test func theFoldersScriptUsesXDG() throws {
        let (folders, home) = try run(
            answers: ["DOWNLOAD": "$HOME/dl", "DESKTOP": "$HOME", "DOCUMENTS": "$HOME/docs"],
            folders: ["dl", "docs"])
        #expect(folders?.downloads == Self.path(home + "/dl"))
        #expect(folders?.desktop == nil)
        #expect(folders?.documents?.name?.shown == "docs")
    }
}
