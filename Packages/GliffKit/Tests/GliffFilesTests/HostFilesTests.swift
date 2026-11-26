#if os(macOS)
    import Foundation
    import GliffSFTP
    import GliffTestSupport
    import GliffTransport
    import Synchronization
    import Testing

    @testable import GliffFiles

    /// The connections a test handed out, newest last.
    final class HandedOut: Sendable {
        let list = Mutex<[SeverableConnection]>([])
    }

    /// A host's files against the system's own `sftp-server`, over connections the test can cut.
    @Suite struct HostFilesTests {
        let source: TemporaryFolder
        let destination: TemporaryFolder
        let store = MemoryLedgerStore()
        let handedOut = HandedOut()
        let transport: PeerTransport

        init() throws {
            (source, destination) = (try TemporaryFolder(), try TemporaryFolder())
            let handedOut = handedOut
            transport = PeerTransport { () async throws(TransportError) in
                let inner = try await ProcessTransport(
                    executable: URL(filePath: "/usr/libexec/sftp-server"), arguments: []
                ).connect()
                // The first connection stalls after 1 MiB written, so a test can cut it mid-file.
                return handedOut.list.withLock { handedOut in
                    let connection = SeverableConnection(
                        inner, stallAfter: handedOut.isEmpty ? 1 << 20 : .max)
                    handedOut.append(connection)
                    return connection
                }
            }
        }

        var home: String { destination.url.path(percentEncoded: false) }
        var target: RemotePath { RemotePath(absolute: Array(home.utf8)) ?? .root }

        func hostFiles(commands: PeerTransport? = nil) -> HostFiles {
            .testing(files: transport, home: home, commands: commands, ledger: TemporaryLedger(store: store))
        }

        func remote(_ name: String, isFolder: Bool = false) -> LedgerEntry {
            .remote(
                host: "omarchy", path: target.appending(RemoteName(raw: Array(name.utf8))!),
                isFolder: isFolder)
        }

        var landed: [String] { (try? LocalFiles.names(in: destination.url)) ?? [] }

        @Test func tryAgainRemovesTheFailedTrysTemporaries() async throws {
            defer {
                source.remove()
                destination.remove()
            }
            let file = try source.file("big.bin")
            try Data(count: 4 << 20).write(to: file)
            let files = hostFiles()
            let batch = await files.enqueue(.upload([file], to: target, clash: .keepBoth), asker: nil)
            #expect(await eventually { batch.progress.counts.bytesDone > 0 })
            await handedOut.list.withLock { $0.last }?.sever()
            #expect(await eventually { batch.progress.counts.state == .failed(.connectionLost) })
            #expect(landed.count == 1 && landed[0].hasPrefix(".big.bin.glifftop-"))
            #expect(store.load().count == 1)

            await files.retry(batch.id, asker: nil)
            #expect(await eventually { batch.progress.counts.state == .finished })
            #expect(landed == ["big.bin"])
            #expect(store.load().isEmpty)
            #expect(transport.connects == 2)
        }

        /// Try Again asks about a taken name through the window that tried again.
        @Test func tryAgainAsksThroughItsOwnWindow() async throws {
            defer {
                source.remove()
                destination.remove()
            }
            let file = try source.file("big.bin")
            try Data(count: 4 << 20).write(to: file)
            try destination.file("big.bin", "taken")
            let first = Mutex(0)
            let second = Mutex(0)
            let files = hostFiles()
            let clash = NameClashPolicy.ask { _, _ in
                first.withLock { $0 += 1 }
                return ClashAnswer(.stop)
            }
            let batch = await files.enqueue(.upload([file], to: target, clash: clash), asker: nil)
            #expect(await eventually { batch.progress.counts.bytesDone > 0 })
            await handedOut.list.withLock { $0.last }?.sever()
            #expect(await eventually { batch.progress.counts.state == .failed(.connectionLost) })

            let retrying = NameClashPolicy.ask { _, _ in
                second.withLock { $0 += 1 }
                return ClashAnswer(.keepBoth)
            }
            await files.retry(batch.id, asker: nil, clash: retrying)
            #expect(await eventually { batch.progress.counts.state == .finished })
            #expect(first.withLock { $0 } == 0)
            #expect(second.withLock { $0 } == 1)
            #expect(landed == ["big 2.bin", "big.bin"])
        }

        /// A name the ledger recorded before this launch goes, with what a folder holds; one
        /// that only looks like it stays.
        @Test func leftoversAreRemovedByExactNameOnly() async throws {
            defer { destination.remove() }
            try destination.file(".a.glifftop-0000000a", "half")
            try destination.file(".b.glifftop-0000000b/inside/c.txt", "c")
            try destination.file(".a.glifftop-0000000c", "not ours")
            let earlier = TemporaryLedger(store: store)
            try await earlier.record(remote(".a.glifftop-0000000a"))
            try await earlier.record(remote(".b.glifftop-0000000b", isFolder: true))
            let files = hostFiles()
            let window = await files.join(asker: nil)
            _ = try await files.session(for: window)
            #expect(landed == [".a.glifftop-0000000c"])
            #expect(store.load().isEmpty)
            await files.leave(window)
        }

        /// A recorded folder that is now a link loses the link only; where it leads is kept.
        @Test func aLeftoverTurnedLinkIsNotFollowed() async throws {
            defer {
                source.remove()
                destination.remove()
            }
            let kept = try source.file("kept/keep.txt", "mine")
            try FileManager.default.createSymbolicLink(
                at: destination.url.appending(path: ".b.glifftop-0000000b"),
                withDestinationURL: source.url.appending(path: "kept"))
            try await TemporaryLedger(store: store).record(remote(".b.glifftop-0000000b", isFolder: true))
            let files = hostFiles()
            let window = await files.join(asker: nil)
            _ = try await files.session(for: window)
            #expect(FileManager.default.fileExists(atPath: kept.path(percentEncoded: false)))
            #expect(landed.isEmpty)
            #expect(store.load().isEmpty)
            await files.leave(window)
        }

        /// Each new session removes what is recorded; the folders are read once.
        @Test func theNextSessionRemovesRecordedLeftovers() async throws {
            defer { destination.remove() }
            let commands = PeerTransport.folders(home: home)
            let files = hostFiles(commands: commands)
            let window = await files.join(asker: nil)
            _ = try await files.session(for: window)
            #expect(await files.folders?.downloads == target)
            await files.leave(window)
            let reopened = await files.join(asker: nil)
            _ = try await files.session(for: reopened)
            #expect(commands.connects == 1)
            await files.leave(reopened)
            #expect(await eventually { handedOut.list.withLock { $0.count } == 2 })

            try destination.file(".a.glifftop-0000000a", "half")
            try await TemporaryLedger(store: store).record(remote(".a.glifftop-0000000a"))
            let next = hostFiles(commands: commands)
            let again = await next.join(asker: nil)
            _ = try await next.session(for: again)
            #expect(landed.isEmpty)
            #expect(store.load().isEmpty)
            #expect(commands.connects == 2)
            await next.leave(again)
        }

        /// A folders command that fails leaves the home sftp-server starts in, as Downloads too.
        @Test func withoutTheFoldersCommandHomeIsWhereSFTPStarts() async throws {
            defer { destination.remove() }
            let files = hostFiles(
                commands: PeerTransport { () throws(TransportError) in
                    throw .exited(status: 127, failure: .other(""))
                })
            let window = await files.join(asker: nil)
            let session = try await files.session(for: window)
            let start = try await session.realpath(Array(".".utf8))
            #expect(await files.folders?.downloads.raw == start)
            await files.leave(window)
        }
    }
#endif
