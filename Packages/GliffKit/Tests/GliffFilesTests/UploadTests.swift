#if os(macOS)
    import Foundation
    import GliffSFTP
    import GliffTestSupport
    import GliffTransport
    import Synchronization
    import Testing

    @testable import GliffFiles

    /// Uploads to the system's own `sftp-server`, from one temporary folder into another.
    @Suite struct UploadTests {
        let source: TemporaryFolder
        let destination: TemporaryFolder
        let store = MemoryLedgerStore()

        init() throws {
            (source, destination) = (try TemporaryFolder(), try TemporaryFolder())
        }

        var target: RemotePath {
            RemotePath(absolute: Array(destination.url.path(percentEncoded: false).utf8)) ?? .root
        }

        /// Plans `names` from the source folder and uploads them into the destination.
        @discardableResult
        func upload(
            _ names: [String], clash: NameClashPolicy = .keepBoth,
            during: @Sendable (TransferProgress, _ cancel: @Sendable () -> Void) async -> Void = { _, _ in }
        ) async throws -> TransferProgress {
            defer { source.remove() }
            let plan = try UploadPlan.upload(names.map { source.url.appending(path: $0) }, to: target)
            let progress = TransferProgress.begun(plan)
            let connection = try await ProcessTransport(
                executable: URL(filePath: "/usr/libexec/sftp-server"), arguments: []
            ).connect()
            let session = try await SFTPSession.start(over: connection)
            let upload = Upload(
                session: session, host: "omarchy", ledger: TemporaryLedger(store: store),
                pipeline: Pipeline(),
                progress: progress, clash: clash)
            let running = Task { try await upload.run(plan) }
            await during(progress) { running.cancel() }
            let result = try await running.resultWithin()
            await session.close()
            try result.get()
            return progress
        }

        /// The destination's names, hidden ones too.
        var landed: [String] { (try? LocalFiles.names(in: destination.url)) ?? [] }

        func contents(_ name: String) throws -> Data {
            try Data(contentsOf: destination.url.appending(path: name))
        }

        @Test func anEmptyFileUploads() async throws {
            defer { destination.remove() }
            try source.file("empty.txt", "")
            let progress = try await upload(["empty.txt"])
            #expect(landed == ["empty.txt"])
            #expect(try contents("empty.txt").isEmpty)
            #expect(progress.counts.itemsDone == 1)
            #expect(store.load().isEmpty)
        }

        @Test func anEightMiBFileUploads() async throws {
            defer { destination.remove() }
            let bytes = Data((0..<8 << 20).map { UInt8(truncatingIfNeeded: $0 &* 31 >> 3) })
            let file = try source.file("disk.img", "")
            try bytes.write(to: file)
            chmod(file.path(percentEncoded: false), 0o640)
            let modified = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            let progress = try await upload(["disk.img"])
            #expect(try contents("disk.img") == bytes)
            let status = TemporaryFolder.status(destination.url.appending(path: "disk.img"))
            #expect(status.st_mode & 0o7777 == 0o640)
            #expect(status.st_mtimespec.tv_sec == 1_700_000_000)
            #expect(progress.counts.bytesDone == 8 << 20)
            #expect(landed == ["disk.img"])
        }

        @Test func aTreeUploadsWithRealNamesInside() async throws {
            defer { destination.remove() }
            let manager = FileManager.default
            try manager.createDirectory(
                at: source.url.appending(path: "photos/sub"), withIntermediateDirectories: true)
            try source.file("photos/a.jpg", "a")
            try source.file("photos/sub/b.jpg", "bb")
            chmod(source.url.appending(path: "photos/sub").path(percentEncoded: false), 0o750)
            let progress = try await upload(["photos"])
            #expect(landed == ["photos"])
            #expect(try contents("photos/a.jpg") == Data("a".utf8))
            #expect(try contents("photos/sub/b.jpg") == Data("bb".utf8))
            #expect(
                TemporaryFolder.status(destination.url.appending(path: "photos/sub")).st_mode & 0o7777
                    == 0o750)
            #expect(progress.counts.itemsDone == 4)
            #expect(store.load().isEmpty)
        }

        @Test func aNameTakenMeanwhileIsNeverOverwritten() async throws {
            defer { destination.remove() }
            try source.file("report.pdf", "new")
            try destination.file("report.pdf", "old")
            await #expect(throws: FilesError.cancelled) {
                try await upload(["report.pdf"], clash: .ask { _, _ in ClashAnswer(.stop) })
            }
            #expect(try contents("report.pdf") == Data("old".utf8))
            #expect(landed == ["report.pdf"])
            #expect(store.load().isEmpty)
        }

        @Test func keepBothAddsTwo() async throws {
            defer { destination.remove() }
            try source.file("report.pdf", "new")
            try FileManager.default.createDirectory(
                at: source.url.appending(path: "photos"), withIntermediateDirectories: false)
            try destination.file("report.pdf", "old")
            try FileManager.default.createDirectory(
                at: destination.url.appending(path: "photos"), withIntermediateDirectories: false)
            try await upload(["report.pdf", "photos"])
            #expect(landed == ["photos", "photos 2", "report 2.pdf", "report.pdf"])
            #expect(try contents("report 2.pdf") == Data("new".utf8))
            #expect(try contents("report.pdf") == Data("old".utf8))
        }

        /// Plain RENAME never replaces, so a replaced file shows `posix-rename` was used.
        @Test func replaceUsesPosixRename() async throws {
            defer { destination.remove() }
            try source.file("report.pdf", "new")
            try destination.file("report.pdf", "old")
            try await upload(["report.pdf"], clash: .ask { _, _ in ClashAnswer(.replace) })
            #expect(landed == ["report.pdf"])
            #expect(try contents("report.pdf") == Data("new".utf8))
        }

        @Test func noReplaceForFolders() async throws {
            defer { destination.remove() }
            try source.file("photos/a.jpg", "new")
            try destination.file("photos/a.jpg", "old")
            let asked = Mutex<[Bool]>([])
            try await upload(
                ["photos"],
                clash: .ask { _, isFolder in
                    asked.withLock { $0.append(isFolder) }
                    return ClashAnswer(.replace)
                })
            #expect(asked.withLock { $0 } == [false])
            #expect(landed == ["photos", "photos 2"])
            #expect(try contents("photos/a.jpg") == Data("old".utf8))
            #expect(try contents("photos 2/a.jpg") == Data("new".utf8))
        }

        /// A file meeting a folder can't replace it: Replace isn't offered, and keeps both.
        @Test func aFileCantReplaceAFolder() async throws {
            defer { destination.remove() }
            try source.file("build", "new")
            try destination.file("build/old.txt", "old")
            let asked = Mutex<[Bool]>([])
            try await upload(
                ["build"],
                clash: .ask { _, canReplace in
                    asked.withLock { $0.append(canReplace) }
                    return ClashAnswer(.replace)
                })
            #expect(asked.withLock { $0 } == [false])
            #expect(landed == ["build", "build 2"])
            #expect(try contents("build/old.txt") == Data("old".utf8))
        }

        /// A folder's RENAME would replace a link that leads nowhere; the name counts as taken.
        @Test func aFolderNeverReplacesADanglingLink() async throws {
            defer { destination.remove() }
            try source.file("photos/a.jpg", "a")
            try FileManager.default.createSymbolicLink(
                atPath: destination.url.appending(path: "photos").path(percentEncoded: false),
                withDestinationPath: "/gone")
            try await upload(["photos"])
            #expect(landed == ["photos", "photos 2"])
            #expect(
                TemporaryFolder.status(destination.url.appending(path: "photos")).st_mode & S_IFMT == S_IFLNK)
        }

        /// A batch cancelled while its question is up stops when the question returns.
        @Test func cancelWhileAskingStops() async throws {
            defer { destination.remove() }
            try source.file("report.pdf", "new")
            try destination.file("report.pdf", "old")
            await #expect(throws: FilesError.cancelled) {
                try await upload(
                    ["report.pdf"],
                    clash: .ask { _, _ in
                        try? await Task.sleep(for: .seconds(30))
                        return ClashAnswer(.replace)
                    }
                ) { _, cancel in
                    try? await Task.sleep(for: .milliseconds(200))
                    cancel()
                }
            }
            #expect(try contents("report.pdf") == Data("old".utf8))
            #expect(landed == ["report.pdf"])
        }

        @Test func applyToAllAsksOnce() async throws {
            defer { destination.remove() }
            for name in ["a.txt", "b.txt"] {
                try source.file(name, "new")
                try destination.file(name, "old")
            }
            let asked = Mutex(0)
            try await upload(
                ["a.txt", "b.txt"],
                clash: .ask { _, _ in
                    asked.withLock { $0 += 1 }
                    return ClashAnswer(.keepBoth, applyToAll: true)
                })
            #expect(asked.withLock { $0 } == 1)
            #expect(landed == ["a 2.txt", "a.txt", "b 2.txt", "b.txt"])
        }

        @Test func cancelLeavesNothingBehind() async throws {
            defer { destination.remove() }
            try Data(count: 64 << 20).write(to: try source.file("big.bin", ""))
            try source.file("photos/a.jpg", "a")
            await #expect(throws: FilesError.cancelled) {
                try await upload(["big.bin", "photos"]) { progress, cancel in
                    _ = await eventually { progress.counts.bytesDone > 0 }
                    cancel()
                }
            }
            #expect(landed.isEmpty)
            #expect(store.load().isEmpty)
        }
    }
#endif
