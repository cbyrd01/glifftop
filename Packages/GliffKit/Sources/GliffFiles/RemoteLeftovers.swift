import GliffSFTP

/// Removes a host's temporaries by their exact recorded names, never by a pattern: a file with
/// REMOVE; a folder, when LSTAT still finds a real directory there, with what it holds (REMOVE
/// for anything not a folder, so no link is followed), then RMDIR, at most
/// `TransferLimits.maxDepth` deep. Anything else at a folder's name (a link put there) is
/// removed alone. One already gone counts as removed.
enum RemoteLeftovers {
    /// Removes each host-side entry, then forgets the ones removed in `ledger`.
    static func remove(_ entries: [LedgerEntry], on session: SFTPSession, ledger: TemporaryLedger) async {
        var removed: Set<LedgerEntry> = []
        for entry in entries {
            guard case .remote(_, let path, let isFolder) = entry,
                await remove(path, isFolder: isFolder, on: session, depth: 1)
            else { continue }
            removed.insert(entry)
        }
        await ledger.forget(all: removed)
    }

    /// Removes one item by its exact path, a folder only when empty; true when it is gone.
    static func removeItem(_ path: RemotePath, isFolder: Bool, on session: SFTPSession) async -> Bool {
        do {
            if isFolder { try await session.rmdir(path.raw) } else { try await session.remove(path.raw) }
            return true
        } catch .noSuchFile {
            return true
        } catch {
            return false
        }
    }

    private static func remove(_ path: RemotePath, isFolder: Bool, on session: SFTPSession, depth: Int) async
        -> Bool
    {
        if isFolder, depth <= TransferLimits.maxDepth {
            do throws(FilesError) {
                guard
                    try await session.lstat(path.raw).permissions.map(SFTPFileType.init(mode:)) == .directory
                else { return await removeItem(path, isFolder: false, on: session) }
                for entry in try await RemoteListing.read(path, on: session).entries {
                    _ = await remove(
                        path.appending(entry.name), isFolder: entry.kind == .directory, on: session,
                        depth: depth + 1)
                }
            } catch .noSuchFile {
                return true
            } catch {
                return false
            }
        }
        return await removeItem(path, isFolder: isFolder, on: session)
    }
}
