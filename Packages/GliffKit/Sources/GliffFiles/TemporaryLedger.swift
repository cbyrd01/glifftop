public import Foundation

/// A temporary name a batch made, on this Mac (a path) or on a host (its exact path there).
public enum LedgerEntry: Codable, Hashable, Sendable {
    case local(path: String)
    case remote(host: String, path: RemotePath, isFolder: Bool)
}

/// Where the ledger lives between launches.
public protocol LedgerStore: Sendable {
    /// The entries saved; empty when there are none or they can't be read.
    func load() -> [LedgerEntry]
    func save(_ entries: [LedgerEntry]) throws
}

/// Every temporary name a batch makes, recorded before it is made and forgotten once it is
/// renamed in or removed, so a quit, a crash or a lost link leaves nothing behind for long:
/// leftovers are removed by their exact recorded names, never by a pattern. The entries hold
/// paths and are never logged. A batch records only its top-level temporaries (what it
/// puts inside one goes with it), so each saves the whole ledger.
public actor TemporaryLedger {
    private let store: any LedgerStore
    private var entries: [LedgerEntry]
    /// What was recorded before this launch: the leftovers. A batch running now owns the rest.
    private let earlier: Set<LedgerEntry>

    public init(store: any LedgerStore) {
        self.store = store
        entries = store.load()
        earlier = Set(entries)
    }

    /// Records `entry` before its name is made; a name that can't be recorded mustn't be made.
    public func record(_ entry: LedgerEntry) throws(FilesError) {
        do {
            try store.save(entries + [entry])
        } catch {
            throw .local(LocalFailure(error: error))
        }
        entries.append(entry)
    }

    /// Forgets `entry` once it is renamed in or removed.
    public func forget(_ entry: LedgerEntry) {
        guard let index = entries.firstIndex(of: entry) else { return }
        entries.remove(at: index)
        try? store.save(entries)
    }

    /// This Mac's temporaries recorded before this launch and not yet forgotten.
    public func localLeftovers() -> [String] {
        entries.compactMap { if case .local(let path) = $0, earlier.contains($0) { path } else { nil } }
    }

    /// `host`'s temporaries recorded before this launch and not yet forgotten.
    public func remoteLeftovers(for host: String) -> [LedgerEntry] {
        entries.filter { if case .remote(host, _, _) = $0 { earlier.contains($0) } else { false } }
    }

    /// Removes each recorded local temporary (a folder with what the batch put in it; a link
    /// is removed, never followed) and forgets it. One whose folder is missing (on a volume
    /// not mounted now) is kept for a later launch.
    public func removeLocalLeftovers() {
        let gone = Set(
            localLeftovers().filter { path in
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch CocoaError.fileNoSuchFile {
                    // Already gone, unless its folder is too.
                    return FileManager.default.fileExists(
                        atPath: URL(filePath: path).deletingLastPathComponent().path(percentEncoded: false))
                } catch {
                    return false
                }
                return true
            })
        guard !gone.isEmpty else { return }
        entries.removeAll { if case .local(let path) = $0 { gone.contains(path) } else { false } }
        try? store.save(entries)
    }
}

/// The ledger as a JSON file (the app's, in Application Support), written atomically before a
/// name is made, which `UserDefaults` doesn't promise; it survives the app's quit or crash, not
/// a power loss (the write isn't synced). An entry that can't be read is skipped, the rest kept.
public struct FileLedgerStore: LedgerStore {
    let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [LedgerEntry] {
        let entries = try? JSONDecoder().decode([Readable].self, from: Data(contentsOf: url))
        return entries?.compactMap(\.entry) ?? []
    }

    /// One entry, or nil when it can't be read.
    private struct Readable: Decodable {
        let entry: LedgerEntry?

        init(from decoder: any Decoder) { entry = try? LedgerEntry(from: decoder) }
    }

    public func save(_ entries: [LedgerEntry]) throws {
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
