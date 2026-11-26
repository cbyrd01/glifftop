import GliffSFTP

extension Upload {
    /// Renames the temporary in as `name`, settling a taken name as the policy says. Plain
    /// RENAME never replaces a file (OpenSSH's is link-then-unlink), and a folder looks first,
    /// so a name taken meanwhile is never overwritten; only Replace uses `posix-rename`, offered
    /// only for a file over a file when the server has it.
    func commit(
        _ temporary: RemotePath, as name: RemoteName, isFolder: Bool, remembered: inout ClashChoice?
    ) async throws(FilesError) {
        guard let existing = try await moved(temporary, to: name, isFolder: isFolder) else { return }
        let canReplace = !isFolder && existing.fileType == .regular && session.extensions.posixRename
        var choice = ClashChoice.keepBoth
        if case .ask(let ask) = clash {
            if let remembered {
                choice = remembered
            } else {
                let answer = await ask(name.shown, canReplace)
                choice = answer.choice
                if answer.applyToAll { remembered = answer.choice }
            }
        }
        if !canReplace, choice == .replace { choice = .keepBoth }
        switch choice {
        case .stop:
            throw .cancelled
        case .replace:
            try await session.posixRename(from: temporary.raw, to: temporary.parent.appending(name).raw)
        case .keepBoth:
            let free = try await NameClash.nextFree(
                String(decoding: name.raw, as: UTF8.self), isFolder: isFolder
            ) {
                (candidate: String) async throws(FilesError) -> Bool in
                guard let next = RemoteName(uploading: candidate) else { throw .failure }
                return try await moved(temporary, to: next, isFolder: isFolder) != nil
            }
            guard free != nil else { throw .failure }
        }
    }

    /// Renames the temporary to `name` beside it: nil once moved, or what already has the name
    /// (a FAILURE, and LSTAT finds it). A FAILURE with nothing there fails as it came. A folder
    /// looks first: sftp-server checks a folder's target with `stat`, which follows a link, so
    /// its RENAME would replace a link that leads nowhere.
    private func moved(
        _ temporary: RemotePath, to name: RemoteName, isFolder: Bool
    ) async throws(FilesError) -> SFTPAttributes? {
        let target = temporary.parent.appending(name)
        if isFolder, let existing = try await existing(target) { return existing }
        do {
            try await session.rename(from: temporary.raw, to: target.raw)
            return nil
        } catch .failure {
            guard let existing = try await existing(target) else { throw .failure }
            return existing
        }
    }

    /// What is at `path`, never following a link; nil when nothing is.
    private func existing(_ path: RemotePath) async throws(FilesError) -> SFTPAttributes? {
        do {
            return try await session.lstat(path.raw)
        } catch .noSuchFile {
            return nil
        }
    }

    /// Removes a temporary and the items of `made` in it, children first, in a task of its own
    /// so a cancelled batch still cleans up; forgets it once it is gone. sftp-server answers in
    /// order, so these go after every abandoned request's reply.
    func remove(
        _ entry: LedgerEntry, temporary: RemotePath, isFolder: Bool, made: ArraySlice<UploadPlan.Item>
    ) async {
        let session = session
        let removed = await Task {
            for item in made.reversed() {
                guard
                    await RemoteLeftovers.removeItem(
                        Self.path(of: item, in: temporary), isFolder: item.isFolder, on: session)
                else { return false }
            }
            return await RemoteLeftovers.removeItem(temporary, isFolder: isFolder, on: session)
        }.value
        if removed { await ledger.forget(entry) }
    }
}

extension RemoteName {
    /// `LocalFiles.temporaryName` of the name.
    func temporary() -> RemoteName? {
        RemoteName(raw: Array(LocalFiles.temporaryName(stem: String(decoding: raw, as: UTF8.self)).utf8))
    }
}
