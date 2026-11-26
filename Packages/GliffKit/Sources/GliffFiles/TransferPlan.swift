public import Foundation
import GliffSFTP

/// The limits on one batch: folders deep, and entries seen (skipped ones included).
public enum TransferLimits {
    public static let maxDepth = 64
    public static let maxEntries = 100_000
}

/// Copying Mac items to a host folder.
public typealias UploadPlan = TransferPlan<URL, RemotePath>
/// Copying host items to a Mac folder.
public typealias DownloadPlan = TransferPlan<RemotePath, URL>

/// What a batch copies, found before any byte moves: regular files and folders only, each
/// folder before what it holds. Links inside a folder, devices, FIFOs, sockets and items
/// without permissions are skipped and counted; a link at the top level is followed, and its
/// target must be a file or folder. Past `TransferLimits` the plan fails (`.tooLarge`).
public struct TransferPlan<Source: Sendable, Destination: Sendable>: Sendable {
    public struct Item: Sendable {
        /// Where it is read from: a link at the top level resolved to its target.
        public let source: Source
        /// Its names under the destination, the top-level item's first.
        public let path: [RemoteName]
        public let isFolder: Bool
        /// Bytes; 0 for a folder.
        public let size: UInt64
        /// The permission bits (`0o7777`), before `FileMetadata.mode` masks them.
        public let mode: UInt32
        /// Seconds since 1970, in SFTP v3's 32 bits; nil when the host sent no times.
        public let modified: UInt32?
    }

    public let destination: Destination
    public private(set) var items: [Item] = []
    /// The files' sizes summed, saturating.
    public private(set) var totalBytes: UInt64 = 0
    public private(set) var linksSkipped = 0
    public private(set) var specialsSkipped = 0
    /// Names that can't be used on the other side.
    public private(set) var unusableNames = 0
    private var entries = 0

    init(destination: Destination) { self.destination = destination }

    /// Counts `count` more entries seen; a cancelled caller stops here.
    private mutating func see(_ count: Int = 1) throws(FilesError) {
        guard !Task.isCancelled else { throw .cancelled }
        entries += count
        guard entries <= TransferLimits.maxEntries else { throw .tooLarge }
    }

    /// Plans an item of `kind` (from its mode's type bits; nil when there are none), or counts
    /// it skipped. True for a folder, whose contents come next.
    private mutating func admit(
        _ source: Source, kind: SFTPFileType?, path: [RemoteName], size: UInt64, mode: UInt32,
        modified: UInt32?
    ) throws(FilesError) -> Bool {
        let isFolder = kind == .directory
        switch kind {
        case .regular, .directory:
            guard path.count <= TransferLimits.maxDepth || !isFolder else { throw .tooLarge }
            let size = isFolder ? 0 : size
            items.append(
                Item(
                    source: source, path: path, isFolder: isFolder, size: size, mode: mode & 0o7777,
                    modified: modified))
            let (sum, overflow) = totalBytes.addingReportingOverflow(size)
            totalBytes = overflow ? .max : sum
        case .link: linksSkipped += 1
        default: specialsSkipped += 1
        }
        return isFolder
    }
}

extension TransferPlan where Source == URL, Destination == RemotePath {
    /// Plans copying `urls` into `destination`, through `lstat`, never following a link
    /// inside a folder.
    public static func upload(_ urls: [URL], to destination: RemotePath) throws(FilesError) -> Self {
        var plan = Self(destination: destination)
        for url in urls {
            try plan.see()
            guard let name = RemoteName(uploading: url.lastPathComponent) else {
                plan.unusableNames += 1
                continue
            }
            var source = url
            var status = try LocalFiles.status(url)
            if status.st_mode & S_IFMT == S_IFLNK {
                // A link that leads nowhere (gone, a loop, out of reach) is skipped.
                guard let target = try? LocalFiles.linkTarget(url) else {
                    plan.linksSkipped += 1
                    continue
                }
                source = target
                status = try LocalFiles.status(source)
            }
            try plan.addLocal(source, status: status, path: [name])
        }
        return plan
    }

    private mutating func addLocal(_ url: URL, status: stat, path: [RemoteName]) throws(FilesError) {
        let isFolder = try admit(
            url, kind: SFTPFileType(mode: UInt32(status.st_mode)), path: path,
            size: UInt64(clamping: status.st_size),
            mode: UInt32(status.st_mode), modified: FileMetadata.time(Int64(status.st_mtimespec.tv_sec)))
        guard isFolder else { return }
        for child in try LocalFiles.names(in: url) {
            try see()
            guard let name = RemoteName(uploading: child) else {
                unusableNames += 1
                continue
            }
            let childURL = url.appending(path: child, directoryHint: .notDirectory)
            try addLocal(childURL, status: LocalFiles.status(childURL), path: path + [name])
        }
    }
}

extension TransferPlan where Source == RemotePath, Destination == URL {
    /// Plans copying `paths` on the host into `destination`, through LSTAT and listings, never
    /// following a link inside a folder.
    public static func download(_ paths: [RemotePath], on session: SFTPSession, to destination: URL)
        async throws(FilesError) -> Self
    {
        var plan = Self(destination: destination)
        for path in paths {
            try plan.see()
            guard let name = path.name else {
                plan.unusableNames += 1
                continue
            }
            var source = path
            var attributes = try await session.lstat(path.raw)
            if attributes.fileType == .link {
                // Read from where the link leads, so the copy never goes through it.
                let resolved: [UInt8]
                do {
                    resolved = try await session.realpath(path.raw)
                } catch .noSuchFile {
                    plan.linksSkipped += 1
                    continue
                }
                guard let target = RemotePath(absolute: resolved) else { throw .protocolBroken }
                source = target
                attributes = try await session.lstat(target.raw)
            }
            try await plan.addRemote(
                source, entry: RemoteEntry(name: name, attributes: attributes), path: [name], on: session)
        }
        return plan
    }

    private mutating func addRemote(
        _ source: RemotePath, entry: RemoteEntry, path: [RemoteName], on session: SFTPSession
    )
        async throws(FilesError)
    {
        // A name with no usable Mac form can't be written there.
        guard entry.name.localName != nil else {
            unusableNames += 1
            return
        }
        let isFolder = try admit(
            source, kind: entry.kind, path: path, size: entry.size ?? 0, mode: entry.permissions ?? 0,
            modified: entry.modified)
        guard isFolder else { return }
        // The listing stops where this batch's entries would run out.
        let listing = try await RemoteListing.read(
            source, on: session, limit: TransferLimits.maxEntries - entries)
        unusableNames += listing.skippedNames
        guard !listing.truncated else { throw .tooLarge }
        try see(listing.skippedNames)
        for child in listing.entries {
            try see()
            try await addRemote(
                source.appending(child.name), entry: child, path: path + [child.name], on: session)
        }
    }
}
