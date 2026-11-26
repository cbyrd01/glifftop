#if os(macOS)
    import Foundation
    import GliffSFTP
    import GliffTestSupport
    import GliffTransport
    import Testing

    @testable import GliffFiles

    /// Downloads from the system's own `sftp-server`, from one temporary folder into another.
    @Suite struct DownloadTests {
        let source: TemporaryFolder
        let destination: TemporaryFolder
        let store = MemoryLedgerStore()

        init() throws {
            (source, destination) = (try TemporaryFolder(), try TemporaryFolder())
        }

        func path(_ name: String) -> RemotePath {
            RemotePath(absolute: Array(source.url.appending(path: name).path(percentEncoded: false).utf8))
                ?? .root
        }

        /// Plans `names` in the source folder and downloads them into the destination;
        /// `beforeRun` runs once the plan is made.
        @discardableResult
        func download(
            _ names: [String], beforeRun: () throws -> Void = {},
            during: @Sendable (TransferProgress, _ cancel: @Sendable () -> Void) async -> Void = { _, _ in }
        ) async throws -> TransferProgress {
            defer { source.remove() }
            let connection = try await ProcessTransport(
                executable: URL(filePath: "/usr/libexec/sftp-server"), arguments: []
            ).connect()
            let session = try await SFTPSession.start(over: connection)
            let plan = try await DownloadPlan.download(names.map(path), on: session, to: destination.url)
            try beforeRun()
            let progress = TransferProgress.begun(plan)
            let download = Download(
                session: session, ledger: TemporaryLedger(store: store), pipeline: Pipeline(),
                progress: progress)
            let running = Task { try await download.run(plan) }
            await during(progress) { running.cancel() }
            let result = try await running.resultWithin()
            await session.close()
            try result.get()
            return progress
        }

        var landed: [String] { (try? LocalFiles.names(in: destination.url)) ?? [] }

        func contents(_ name: String) throws -> Data {
            try Data(contentsOf: destination.url.appending(path: name))
        }

        func isQuarantined(_ name: String) -> Bool {
            TemporaryFolder.quarantine(of: destination.url.appending(path: name)) != nil
        }

        @Test func aFileDownloadsAndIsQuarantined() async throws {
            defer { destination.remove() }
            let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7 >> 2) })
            let file = try source.file("report.pdf")
            try bytes.write(to: file)
            chmod(file.path(percentEncoded: false), 0o640)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
            let progress = try await download(["report.pdf"])
            #expect(landed == ["report.pdf"])
            #expect(try contents("report.pdf") == bytes)
            #expect(isQuarantined("report.pdf"))
            let status = TemporaryFolder.status(destination.url.appending(path: "report.pdf"))
            #expect(status.st_mode & 0o7777 == 0o640)
            #expect(status.st_mtimespec.tv_sec == 1_700_000_000)
            #expect(progress.counts.bytesDone == 3_000_000 && progress.counts.itemsDone == 1)
            #expect(store.load().isEmpty)
        }

        @Test func aTreeDownloadsWithItsModes() async throws {
            defer { destination.remove() }
            try source.file("photos/a.jpg", "a")
            try source.file("photos/sub/b.jpg", "bb")
            chmod(source.url.appending(path: "photos/sub").path(percentEncoded: false), 0o750)
            chmod(source.url.appending(path: "photos/a.jpg").path(percentEncoded: false), 0o604)
            let progress = try await download(["photos"])
            #expect(landed == ["photos"])
            #expect(try contents("photos/sub/b.jpg") == Data("bb".utf8))
            #expect(
                TemporaryFolder.status(destination.url.appending(path: "photos/sub")).st_mode & 0o7777
                    == 0o750)
            #expect(
                TemporaryFolder.status(destination.url.appending(path: "photos/a.jpg")).st_mode & 0o7777
                    == 0o604)
            #expect(["photos", "photos/a.jpg", "photos/sub/b.jpg"].allSatisfy(isQuarantined))
            #expect(progress.counts.itemsDone == 4)
            #expect(store.load().isEmpty)
        }

        @Test func aFileLargerThanPlannedFails() async throws {
            defer { destination.remove() }
            let file = try source.file("log.txt", "short")
            await #expect(throws: FilesError.changedWhileCopying) {
                try await download(["log.txt"]) { try Data(count: 2 << 20).write(to: file) }
            }
            #expect(landed.isEmpty)
            #expect(store.load().isEmpty)
        }

        @Test func anExistingNameGetsTwo() async throws {
            defer { destination.remove() }
            try source.file("report.pdf", "new")
            try destination.file("report.pdf", "old")
            try await download(["report.pdf"])
            #expect(landed == ["report 2.pdf", "report.pdf"])
            #expect(try contents("report 2.pdf") == Data("new".utf8))
            #expect(try contents("report.pdf") == Data("old".utf8))
        }

        /// A folder whose name is taken lands as "photos 2"; the existing one is left as it was.
        @Test func nothingIsWrittenOutsideTheBatchsFolder() async throws {
            defer { destination.remove() }
            try source.file("photos/a.jpg", "new")
            try source.file("photos/b.jpg", "new")
            try destination.file("photos/a.jpg", "old")
            try await download(["photos"])
            #expect(landed == ["photos", "photos 2"])
            #expect((try? LocalFiles.names(in: destination.url.appending(path: "photos"))) == ["a.jpg"])
            #expect(try contents("photos/a.jpg") == Data("old".utf8))
            #expect(try contents("photos 2/b.jpg") == Data("new".utf8))
        }

        /// sftp-server would wait on a FIFO's OPEN, holding the whole session up.
        @Test func aFileTurnedFIFOAfterPlanningIsSkipped() async throws {
            defer { destination.remove() }
            try source.file("photos/a.jpg", "a")
            let b = try source.file("photos/b.jpg", "b")
            let progress = try await download(["photos"]) {
                try FileManager.default.removeItem(at: b)
                #expect(mkfifo(b.path(percentEncoded: false), 0o644) == 0)
            }
            #expect((try? LocalFiles.names(in: destination.url.appending(path: "photos"))) == ["a.jpg"])
            #expect(progress.counts.specialsSkipped == 1 && progress.counts.itemsDone == 3)
        }

        /// OPEN follows a link, so a file swapped for one would copy whatever it leads to.
        @Test func aFileTurnedLinkAfterPlanningIsSkipped() async throws {
            defer { destination.remove() }
            let report = try source.file("report.pdf", "report")
            try source.file("elsewhere.txt", "not planned")
            let progress = try await download(["report.pdf"]) {
                try FileManager.default.removeItem(at: report)
                try FileManager.default.createSymbolicLink(
                    at: report, withDestinationURL: source.url.appending(path: "elsewhere.txt"))
            }
            #expect(landed.isEmpty)
            #expect(progress.counts.specialsSkipped == 1 && progress.counts.itemsDone == 1)
            #expect(store.load().isEmpty)
        }

        @Test func cancelLeavesNoLocalTemporary() async throws {
            defer { destination.remove() }
            try Data(count: 64 << 20).write(to: try source.file("big.bin"))
            await #expect(throws: FilesError.cancelled) {
                try await download(
                    ["big.bin"],
                    during: { progress, cancel in
                        _ = await eventually { progress.counts.bytesDone > 0 }
                        cancel()
                    })
            }
            #expect(landed.isEmpty)
            #expect(store.load().isEmpty)
        }
    }
#endif
