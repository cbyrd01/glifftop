import GliffSFTP

/// A host folder's items, read under the limits on host input.
///
/// - `.` and `..` are skipped; a name `RemoteName` refuses, or one already listed, is skipped
///   and counted. Hidden names are kept: a view shows them or not (`RemoteName.isHidden`).
/// - Past `maxEntries` items (`.` and `..` aside) or `maxNameBytes` of names from the host, the
///   listing stops reading and says so (`truncated`).
/// - Reading sends no STAT, so the listing comes back before any link is looked up:
///   `lookUpLinks` finds the targets of at most `maxLinkLookups` links afterwards. sftp-server
///   answers in order, so a STAT stuck in a hung mount holds the session up until its time
///   limit ends it, and `lookUpLinks` then throws.
public struct RemoteListing: Equatable, Sendable {
    public let folder: RemotePath
    public var entries: [RemoteEntry] = []
    /// Names that can't be shown or used ("1 item with an unusable name isn't shown").
    public var skippedNames = 0
    public var truncated = false

    public static let maxEntries = 100_000
    public static let maxNameBytes = 16 << 20
    public static let maxLinkLookups = 256

    /// Reads `folder`. A folder read to its end is kept though the host fails to close it.
    public static func read(_ folder: RemotePath, on session: SFTPSession) async throws(FilesError)
        -> RemoteListing
    {
        let handle = try await session.opendir(folder.raw)
        defer { try? await session.close(handle: handle) }
        var listing = RemoteListing(folder: folder)
        try await listing.fill(from: handle, on: session)
        return listing
    }

    private mutating func fill(from handle: [UInt8], on session: SFTPSession) async throws(FilesError) {
        var received = 0
        var nameBytes = 0
        var listed: Set<RemoteName> = []
        while let batch = try await session.readdir(handle: handle) {
            for item in batch {
                let isDotEntry = RemoteName.isDotEntry(item.name)
                if !isDotEntry { received += 1 }
                nameBytes += item.name.count
                guard received <= Self.maxEntries, nameBytes <= Self.maxNameBytes else {
                    truncated = true
                    return
                }
                guard !isDotEntry else { continue }
                guard let name = RemoteName(raw: item.name), listed.insert(name).inserted else {
                    skippedNames += 1
                    continue
                }
                entries.append(RemoteEntry(name: name, attributes: item.attributes))
            }
        }
    }

    /// STATs the first `maxLinkLookups` links, all at once. A lookup the host refuses leaves
    /// the target unknown; any other failure (the session ended, the caller cancelled) is
    /// thrown once every lookup has come back.
    public mutating func lookUpLinks(on session: SFTPSession) async throws(FilesError) {
        let links = entries.indices.filter { entries[$0].kind == .link }.prefix(Self.maxLinkLookups)
        let ending = await withTaskGroup(of: (Int, Result<SFTPFileType?, FilesError>).self) { group in
            for index in links {
                let path = folder.appending(entries[index].name).raw
                group.addTask {
                    do throws(FilesError) {
                        return (index, .success(try await session.stat(path).fileType))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var ending: FilesError?
            for await (index, result) in group {
                switch result {
                case .success(let target): entries[index].linkTarget = target
                case .failure(.permissionDenied), .failure(.noSuchFile), .failure(.failure),
                    .failure(.unsupported):
                    break
                case .failure(let error): ending = ending ?? error
                }
            }
            return ending
        }
        if let ending { throw ending }
    }
}
