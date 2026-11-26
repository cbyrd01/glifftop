import GliffSFTP

/// Copies a planned batch from this Mac to the host, so a half-written item never carries its
/// real name there.
///
/// - `statvfs` (when offered) must show the batch's bytes free before any byte goes.
/// - A top-level file is written to `.<name>.glifftop-<8 hex>` beside its destination, opened
///   `CREAT | EXCL | WRITE` with its final permissions, so it is never more readable than it
///   will be; then its times (and permissions again, past the host's umask), `fsync` when
///   offered, CLOSE, and RENAME to its name.
/// - A top-level folder is made under such a name with its final permissions and filled under
///   real names, up to 8 files at once within the server's open-handle limit, with no
///   per-file temporary or `fsync`; its folders' times are set once they are full, then it is
///   renamed in.
/// - Each temporary is in the ledger before it is made, and forgotten once renamed in or
///   removed. A failure or a cancel removes it, and what the batch made in it, by name; one
///   that can't be removed stays in the ledger for a later session.
/// - The batch stops at the first item that fails; items already copied stay.
public struct Upload: Sendable {
    let session: SFTPSession
    let host: String
    let ledger: TemporaryLedger
    let pipeline: Pipeline
    let progress: TransferProgress
    let clash: NameClashPolicy

    public init(
        session: SFTPSession, host: String, ledger: TemporaryLedger, pipeline: Pipeline,
        progress: TransferProgress, clash: NameClashPolicy
    ) {
        (self.session, self.host, self.ledger, self.pipeline, self.progress, self.clash) =
            (session, host, ledger, pipeline, progress, clash)
    }

    public func run(_ plan: UploadPlan) async throws(FilesError) {
        if session.extensions.statvfs {
            let space = try await session.statvfs(plan.destination.raw)
            guard space.availableBytes >= plan.totalBytes else { throw .noSpace }
        }
        let settings = try await TransferSettings.read(on: session, chunk: \.writeChunk)
        var remembered: ClashChoice?
        for (top, contents) in plan.topLevel {
            try await upload(
                top, contents: contents, into: plan.destination, settings: settings, remembered: &remembered)
            progress.finishTopLevel()
        }
    }

    /// Uploads one top-level item and what it holds under a temporary name, then renames it in.
    private func upload(
        _ top: UploadPlan.Item, contents: ArraySlice<UploadPlan.Item>, into destination: RemotePath,
        settings: TransferSettings, remembered: inout ClashChoice?
    ) async throws(FilesError) {
        guard let name = top.path.last, let temporaryName = name.temporary() else { throw .failure }
        let temporary = destination.appending(temporaryName)
        let entry = LedgerEntry.remote(host: host, path: temporary, isFolder: top.isFolder)
        try await ledger.record(entry)
        // Until the temporary is made, its name isn't the batch's to remove.
        var made: Int?
        do throws(FilesError) {
            var copied = true
            if top.isFolder {
                try await fill(top, at: temporary, contents: contents, settings: settings, made: &made)
            } else {
                var created = false
                defer { made = created ? 0 : nil }
                copied = try await copy(
                    top, to: temporary, block: settings.block, flush: settings.flush, created: &created)
            }
            if copied {
                try await commit(temporary, as: name, isFolder: top.isFolder, remembered: &remembered)
            }
        } catch {
            if let made {
                await remove(entry, temporary: temporary, isFolder: top.isFolder, made: contents.prefix(made))
            } else {
                await ledger.forget(entry)
            }
            throw error
        }
        await ledger.forget(entry)
    }

    /// Makes the folder at `temporary` and fills it (`FolderFill`). `made` is set once the
    /// folder is made, and counts the items of `contents` begun.
    private func fill(
        _ top: UploadPlan.Item, at temporary: RemotePath, contents: ArraySlice<UploadPlan.Item>,
        settings: TransferSettings, made: inout Int?
    ) async throws(FilesError) {
        try await session.mkdir(temporary.raw, attributes: SFTPAttributes(permissions: Self.mode(top)))
        made = 0
        progress.finishItem()
        try await FolderFill.run(contents, atOnce: settings.filesAtOnce) {
            (item) async throws(FilesError) -> FolderFill.Copy? in
            made? += 1
            let path = Self.path(of: item, in: temporary)
            guard !item.isFolder else {
                try await session.mkdir(path.raw, attributes: SFTPAttributes(permissions: Self.mode(item)))
                progress.finishItem()
                return nil
            }
            return { () async throws(FilesError) in
                var created = false
                _ = try await copy(item, to: path, block: settings.block, flush: false, created: &created)
            }
        }
        // Filling a folder sets its time, so the times go on once every folder is full. Setting
        // one folder's times leaves its parent's alone, so they go together.
        let session = session
        try await pipeline.each(contents.filter(\.isFolder) + [top]) { (item) async throws(FilesError) in
            let path = Self.path(of: item, in: temporary)
            try await session.setstat(path.raw, attributes: Self.attributes(item))
        }
    }

    /// Copies one file to the new name `path`, setting `created` once the host has made it;
    /// false when the Mac's item is no longer a regular file (skipped, counted and done).
    private func copy(
        _ item: UploadPlan.Item, to path: RemotePath, block: UInt32, flush: Bool, created: inout Bool
    ) async throws(FilesError) -> Bool {
        guard let file = try LocalFiles.openForReading(item.source) else {
            progress.skipSpecial()
            progress.finishItem()
            return false
        }
        let handle = try await session.open(
            path.raw, flags: [.write, .create, .exclusive],
            attributes: SFTPAttributes(permissions: Self.mode(item)))
        created = true
        do throws(FilesError) {
            try await pipeline.send(
                file, count: file.size, to: handle, on: session, block: block, progress: progress)
            try await session.fsetstat(handle: handle, attributes: Self.attributes(item))
            if flush { try await session.fsync(handle: handle, bytesWritten: file.size) }
        } catch {
            try? await session.close(handle: handle)
            throw error
        }
        try await session.close(handle: handle)
        progress.finishItem()
        return true
    }

    static func mode(_ item: UploadPlan.Item) -> UInt32 {
        UInt32(FileMetadata.mode(item.mode, isFolder: item.isFolder))
    }

    /// An item's final permissions and times (access set to modified).
    static func attributes(_ item: UploadPlan.Item) -> SFTPAttributes {
        SFTPAttributes(
            permissions: mode(item), times: item.modified.map { SFTPTimes(access: $0, modification: $0) })
    }

    /// Where an item goes under its top-level item's temporary name.
    static func path(of item: UploadPlan.Item, in temporary: RemotePath) -> RemotePath {
        item.path.dropFirst().reduce(temporary) { $0.appending($1) }
    }
}
