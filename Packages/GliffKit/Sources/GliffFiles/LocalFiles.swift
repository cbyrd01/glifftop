public import Foundation

/// An open file on this Mac, by descriptor: read or written at offsets, closed when released.
public final class LocalFile: Sendable {
    let descriptor: Int32
    /// Its size when opened for reading; 0 for a new one.
    public let size: UInt64

    init(descriptor: Int32, size: UInt64 = 0) {
        (self.descriptor, self.size) = (descriptor, size)
    }

    deinit { Darwin.close(descriptor) }

    /// Up to `count` bytes at `offset`; fewer at the end. A signal's interruption is retried.
    public func read(at offset: UInt64, count: Int) throws(FilesError) -> [UInt8] {
        var failure: Int32 = 0
        let bytes = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            var read: Int
            repeat {
                read = pread(descriptor, buffer.baseAddress, count, off_t(offset))
            } while read < 0 && errno == EINTR
            if read < 0 { failure = errno }
            initialized = max(read, 0)
        }
        guard failure == 0 else { throw .local(LocalFailure(errno: failure)) }
        return bytes
    }

    /// Writes all of `bytes` at `offset`. A signal's interruption is retried.
    public func write(_ bytes: [UInt8], at offset: UInt64) throws(FilesError) {
        var done = 0
        while done < bytes.count {
            let wrote = bytes.withUnsafeBytes {
                pwrite(
                    descriptor, $0.baseAddress?.advanced(by: done), bytes.count - done,
                    off_t(offset) + off_t(done))
            }
            if wrote < 0 && errno == EINTR { continue }
            guard wrote > 0 else { throw .local(LocalFailure(errno: wrote < 0 ? errno : EIO)) }
            done += wrote
        }
    }

    /// Sets a file's final permissions (`FileMetadata.mode`) and its times, by descriptor.
    public func finish(mode: UInt32, modified: UInt32) throws(FilesError) {
        try apply(FileMetadata.mode(mode, isFolder: false), modified: modified)
    }

    fileprivate func apply(_ mode: mode_t, modified: UInt32) throws(FilesError) {
        let time = timespec(tv_sec: Int(modified), tv_nsec: 0)
        guard fchmod(descriptor, mode) == 0, futimens(descriptor, [time, time]) == 0 else {
            throw .local(LocalFailure(errno: errno))
        }
    }
}

/// The Mac's side of a transfer, through POSIX calls that never follow a link or block.
public enum LocalFiles {
    /// Opens a regular file for reading, never following a link and never blocking on a FIFO;
    /// nil for anything else (a link, a FIFO, a device, a socket, a folder), found by `lstat`
    /// before opening and by `fstat` after, in case the item changed between.
    public static func openForReading(_ url: URL) throws(FilesError) -> LocalFile? {
        let path = url.path(percentEncoded: false)
        var status = stat()
        if lstat(path, &status) == 0, status.st_mode & S_IFMT != S_IFREG { return nil }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP { return nil }
            throw .local(LocalFailure(errno: errno))
        }
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            return nil
        }
        return LocalFile(descriptor: descriptor, size: UInt64(max(status.st_size, 0)))
    }

    /// Where a temporary of `stem` goes in `folder`: `.<stem>.glifftop-<8 hex>`, the stem cut
    /// on a character boundary so the name fits 255 bytes as a file URL keeps it, decomposed;
    /// a `/` or NUL in the stem becomes `_`, so the temporary stays in `folder`.
    public static func temporaryURL(in folder: URL, stem: String) -> URL {
        let suffix = String(format: ".glifftop-%08x", UInt32.random(in: .min ... .max))
        var cut = Substring(
            stem.decomposedStringWithCanonicalMapping.map { $0 == "/" || $0 == "\0" ? "_" : $0 })
        while cut.utf8.count > 255 - 1 - suffix.utf8.count { cut.removeLast() }
        return folder.appending(path: "." + cut + suffix, directoryHint: .notDirectory)
    }

    /// Creates a new file at `url`, mode 0600, never replacing or following anything.
    public static func createTemporaryFile(at url: URL) throws(FilesError) -> LocalFile {
        let descriptor = open(
            url.path(percentEncoded: false), O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC,
            mode_t(0o600))
        guard descriptor >= 0 else { throw .local(LocalFailure(errno: errno)) }
        return LocalFile(descriptor: descriptor)
    }

    /// Creates a new folder at `url`, mode 0700.
    public static func makeTemporaryFolder(at url: URL) throws(FilesError) {
        guard mkdir(url.path(percentEncoded: false), 0o700) == 0 else {
            throw .local(LocalFailure(errno: errno))
        }
    }

    /// Sets a folder's final permissions (`FileMetadata.mode`) and times, never following a link.
    public static func finishFolder(_ url: URL, mode: UInt32, modified: UInt32) throws(FilesError) {
        let descriptor = open(
            url.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw .local(LocalFailure(errno: errno)) }
        try LocalFile(descriptor: descriptor).apply(
            FileMetadata.mode(mode, isFolder: true), modified: modified)
    }

    /// Moves a temporary in under `name` in its own folder: never over an existing item unless
    /// `replacing`. `name` must be one name, under `RemoteName`'s rule.
    public static func moveIn(_ temporary: URL, as name: String, replacing: Bool) throws(FilesError) {
        guard RemoteName(raw: Array(name.utf8)) != nil else {
            throw .local(.failure)
        }
        let from = temporary.path(percentEncoded: false)
        let to = temporary.deletingLastPathComponent().appending(path: name).path(percentEncoded: false)
        if replacing {
            guard rename(from, to) == 0 else { throw .local(LocalFailure(errno: errno)) }
            return
        }
        guard renamex_np(from, to, UInt32(RENAME_EXCL)) != 0 else { return }
        guard errno == ENOTSUP else { throw .local(LocalFailure(errno: errno)) }
        // A volume without RENAME_EXCL (some network and FAT volumes) is checked, then renamed.
        var status = stat()
        if lstat(to, &status) == 0 { throw .local(.nameTaken) }
        guard errno == ENOENT, rename(from, to) == 0 else { throw .local(LocalFailure(errno: errno)) }
    }

    /// The bytes free to this user on `url`'s volume; nil when the system can't say.
    public static func freeSpace(at url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
    }
}

/// Permissions and times, the same both ways.
public enum FileMetadata {
    /// The source's mode masked to 0o755, with the owner's read and write (files) or read,
    /// write and search (folders) added: never setuid, setgid or sticky.
    public static func mode(_ source: UInt32, isFolder: Bool) -> mode_t {
        mode_t(source & 0o755 | (isFolder ? 0o700 : 0o600))
    }

    /// Seconds since 1970 in SFTP v3's 32 bits: before 1970 is 0, past 2106 the last.
    public static func time(_ seconds: Int64) -> UInt32 {
        UInt32(clamping: seconds)
    }
}
