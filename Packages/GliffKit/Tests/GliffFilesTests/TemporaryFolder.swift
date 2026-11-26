import Foundation

/// A new folder for one test, removed by `remove()`.
struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "GliffFiles-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    /// Writes `text` to a new file at `name` (a relative path) in the folder, making the
    /// folders on the way.
    @discardableResult
    func file(_ name: String, _ text: String = "") throws -> URL {
        let file = url.appending(path: name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    /// A UNIX socket bound at `name` in the folder, and its descriptor for the test to close.
    func socket(_ name: String) throws -> (URL, Int32) {
        let socketURL = url.appending(path: name)
        let path = socketURL.path(percentEncoded: false).utf8
        var address = sockaddr_un()
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        return (socketURL, descriptor)
    }

    /// An item's status, never following a link.
    static func status(_ url: URL) -> stat {
        var status = stat()
        lstat(url.path(percentEncoded: false), &status)
        return status
    }

    /// An item's `com.apple.quarantine`, never following a link; nil when it has none.
    static func quarantine(of url: URL) -> String? {
        let path = url.path(percentEncoded: false)
        let size = getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        _ = getxattr(path, "com.apple.quarantine", &bytes, size, 0, XATTR_NOFOLLOW)
        return String(decoding: bytes, as: UTF8.self)
    }
}
