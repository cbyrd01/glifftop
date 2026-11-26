import Foundation
import GliffSFTP

/// Copies a planned batch from the host to this Mac, so a half-written item never carries its
/// real name here, and nothing outside the batch's own new files and folders is written.
///
/// - The volume's free space must hold the batch's bytes before any byte comes.
/// - A top-level file is written to `.<name>.glifftop-<8 hex>` beside its destination, created
///   0600 and never over anything; then its final permissions, its time and the quarantine,
///   and it is moved in under its name, or the first free "name 2" (Finder's way).
/// - A top-level folder is made under such a name (0700) and filled under real names, up to
///   8 files at once; a name this Mac takes as one already there (case, normalization) gets
///   " 2" and is counted. Every item is quarantined, the folders get their final permissions
///   and times once full, and it is moved in as a file is.
/// - Each temporary is in the ledger before it is made, and forgotten once moved in or
///   removed. A failure or a cancel removes it with what it holds.
/// - The batch stops at the first item that fails; items already copied stay. A download never
///   asks about a name: the Files window asks only for uploads.
public struct Download: Sendable {
    let session: SFTPSession
    let ledger: TemporaryLedger
    let pipeline: Pipeline
    let progress: TransferProgress

    public init(session: SFTPSession, ledger: TemporaryLedger, pipeline: Pipeline, progress: TransferProgress)
    {
        (self.session, self.ledger, self.pipeline, self.progress) = (session, ledger, pipeline, progress)
    }

    public func run(_ plan: DownloadPlan) async throws(FilesError) {
        if let free = LocalFiles.freeSpace(at: plan.destination), free < plan.totalBytes { throw .noSpace }
        let settings = try await TransferSettings.read(on: session, chunk: \.readChunk)
        for (top, contents) in plan.topLevel {
            guard !Task.isCancelled else { throw .cancelled }
            try await download(top, contents: contents, into: plan.destination, settings: settings)
            progress.finishTopLevel()
        }
    }

    /// Downloads one top-level item and what it holds under a temporary name, then moves it in.
    private func download(
        _ top: DownloadPlan.Item, contents: ArraySlice<DownloadPlan.Item>, into destination: URL,
        settings: TransferSettings
    ) async throws(FilesError) {
        guard let name = top.path.last?.localName else { throw .local(.failure) }
        let temporary = LocalFiles.temporaryURL(in: destination, stem: name)
        let entry = LedgerEntry.local(path: temporary.path(percentEncoded: false))
        try await ledger.record(entry)
        var made = false
        do throws(FilesError) {
            var copied = true
            if top.isFolder {
                try LocalFiles.makeTemporaryFolder(at: temporary)
                made = true
                try await fill(top, at: temporary, contents: contents, settings: settings)
            } else {
                let file = try LocalFiles.createTemporaryFile(at: temporary)
                made = true
                copied = try await copy(top, into: file, at: temporary, block: settings.block)
            }
            guard copied else {
                await remove(entry, temporary: temporary)
                return
            }
            try await moveIn(temporary, as: name, isFolder: top.isFolder)
        } catch {
            if made { await remove(entry, temporary: temporary) } else { await ledger.forget(entry) }
            throw error
        }
        await ledger.forget(entry)
    }

    /// Removes a temporary with what it holds and forgets it; one that can't be removed stays
    /// in the ledger, for the next launch.
    private func remove(_ entry: LedgerEntry, temporary: URL) async {
        guard (try? FileManager.default.removeItem(at: temporary)) != nil else { return }
        await ledger.forget(entry)
    }

    /// Fills the folder at `temporary` (`FolderFill`), each item under its own name or, when
    /// this Mac takes that as one already there, the first free "name 2"; then gives every
    /// folder its final permissions and time, the top one last.
    private func fill(
        _ top: DownloadPlan.Item, at temporary: URL, contents: ArraySlice<DownloadPlan.Item>,
        settings: TransferSettings
    ) async throws(FilesError) {
        progress.finishItem()
        // Where each folder landed, by its path in the plan.
        var folders: [ArraySlice<RemoteName>: URL] = [top.path[...]: temporary]
        try await FolderFill.run(contents, atOnce: settings.filesAtOnce) {
            (item) async throws(FilesError) -> FolderFill.Copy? in
            guard let parent = folders[item.path.dropLast()], let name = item.path.last?.localName else {
                throw .local(.failure)
            }
            if item.isFolder {
                let (url, _) = try await create(
                    name, in: parent, isFolder: true, make: LocalFiles.makeTemporaryFolder)
                folders[item.path[...]] = url
                progress.finishItem()
                return nil
            }
            let (url, file) = try await create(
                name, in: parent, isFolder: false, make: LocalFiles.createTemporaryFile)
            return { () async throws(FilesError) in
                // A skipped item's empty file goes; it was made new, so it is the batch's.
                if try await !copy(item, into: file, at: url, block: settings.block) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        for item in contents.reversed() where item.isFolder {
            if let url = folders[item.path[...]] { try finish(item, folder: url) }
        }
        try finish(top, folder: temporary)
    }

    /// Makes a new item called `name` in `folder` through `make`, which never replaces; on a
    /// name taken, the next free one, counted as renamed.
    private func create<Made>(
        _ name: String, in folder: URL, isFolder: Bool, make: (URL) throws(FilesError) -> Made
    ) async throws(FilesError) -> (URL, Made) {
        var made: Made?
        let free = try await Self.firstFree(name, isFolder: isFolder) { (candidate) throws(FilesError) in
            made = try make(folder.appending(path: candidate))
        }
        if free != name { progress.rename() }
        // `firstFree` returns only once `make` has succeeded.
        guard let made else { throw .local(.failure) }
        return (folder.appending(path: free), made)
    }

    /// Reads one host file into `file` (made new at `url`), then sets its final permissions
    /// and time and quarantines it. False when the host's item is no longer a regular file
    /// (skipped, counted and done): LSTAT before OPEN, as OPEN follows a link and waits on a
    /// FIFO, and FSTAT after, for a change between.
    private func copy(
        _ item: DownloadPlan.Item, into file: LocalFile, at url: URL, block: UInt32
    ) async throws(FilesError) -> Bool {
        guard try await session.lstat(item.source.raw).fileType == .regular else { return skipped() }
        let handle = try await session.open(item.source.raw, flags: [.read], attributes: SFTPAttributes())
        do throws(FilesError) {
            guard try await session.fstat(handle: handle).fileType == .regular else {
                try await session.close(handle: handle)
                return skipped()
            }
            try await pipeline.receive(
                handle, count: item.size, into: file, on: session, block: block, progress: progress)
        } catch {
            try? await session.close(handle: handle)
            throw error
        }
        try await session.close(handle: handle)
        try file.finish(mode: item.mode, modified: item.modified)
        try Self.quarantine(url)
        progress.finishItem()
        return true
    }

    private func skipped() -> Bool {
        progress.skipSpecial()
        progress.finishItem()
        return false
    }

    private func finish(_ item: DownloadPlan.Item, folder url: URL) throws(FilesError) {
        try Self.quarantine(url)
        try LocalFiles.finishFolder(url, mode: item.mode, modified: item.modified)
    }

    /// Moves a temporary in under `name`, or the first free "name 2", never over anything.
    private func moveIn(_ temporary: URL, as name: String, isFolder: Bool) async throws(FilesError) {
        _ = try await Self.firstFree(name, isFolder: isFolder) { (candidate) throws(FilesError) in
            try LocalFiles.moveIn(temporary, as: candidate, replacing: false)
        }
    }

    /// The first of `name`, "name 2"… that `take` takes without finding it taken.
    private static func firstFree(
        _ name: String, isFolder: Bool, take: (String) throws(FilesError) -> Void
    ) async throws(FilesError) -> String {
        let free = try await NameClash.nextFree(name, isFolder: isFolder) { (candidate) throws(FilesError) in
            do throws(FilesError) {
                try take(candidate)
            } catch .local(.nameTaken) {
                return true
            }
            return false
        }
        guard let free else { throw .local(.nameTaken) }
        return free
    }

    private static func quarantine(_ url: URL) throws(FilesError) {
        #if os(macOS)
            try Quarantine.apply(to: url)
        #endif
    }
}
