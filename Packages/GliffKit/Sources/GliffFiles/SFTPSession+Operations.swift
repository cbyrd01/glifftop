public import GliffSFTP

/// One typed call per request. Paths and handles are bytes, as the host sends them. A reply of
/// the wrong shape (`ExpectedReply`) has already ended the session as broken; a STATUS other
/// than OK throws its `FilesError`.
extension SFTPSession {
    public func open(
        _ path: [UInt8], flags: SFTPOpenFlags, attributes: SFTPAttributes = SFTPAttributes()
    ) async throws(FilesError) -> [UInt8] {
        try await handle(.open(path: path, flags: flags, attributes: attributes))
    }

    /// Goes out, and is answered, even from a cancelled task: it runs in a task of its own.
    public func close(handle: [UInt8]) async throws(FilesError) {
        let closing = Task { () async -> Result<Void, FilesError> in
            do throws(FilesError) {
                return .success(try await status(.close(handle: handle)))
            } catch {
                return .failure(error)
            }
        }
        try await closing.value.get()
    }

    /// Up to `length` bytes at `offset`; nil at the end of the file. A length of 0 sends nothing and
    /// returns no bytes.
    public func read(handle: [UInt8], offset: UInt64, length: UInt32) async throws(FilesError) -> [UInt8]? {
        guard length > 0 else { return [] }
        return try await untilEndOfFile(.read(handle: handle, offset: offset, length: length)) {
            if case .data(_, let bytes) = $0 { bytes } else { nil }
        }
    }

    public func write(handle: [UInt8], offset: UInt64, data: [UInt8]) async throws(FilesError) {
        try await status(.write(handle: handle, offset: offset, data: data))
    }

    public func lstat(_ path: [UInt8]) async throws(FilesError) -> SFTPAttributes {
        try await attributes(.lstat(path: path))
    }

    public func stat(_ path: [UInt8]) async throws(FilesError) -> SFTPAttributes {
        try await attributes(.stat(path: path))
    }

    public func fstat(handle: [UInt8]) async throws(FilesError) -> SFTPAttributes {
        try await attributes(.fstat(handle: handle))
    }

    public func setstat(_ path: [UInt8], attributes: SFTPAttributes) async throws(FilesError) {
        try await status(.setstat(path: path, attributes: attributes))
    }

    public func fsetstat(handle: [UInt8], attributes: SFTPAttributes) async throws(FilesError) {
        try await status(.fsetstat(handle: handle, attributes: attributes))
    }

    public func opendir(_ path: [UInt8]) async throws(FilesError) -> [UInt8] {
        try await handle(.opendir(path: path))
    }

    /// The next entries; nil at the end of the folder.
    public func readdir(handle: [UInt8]) async throws(FilesError) -> [SFTPNameEntry]? {
        try await untilEndOfFile(.readdir(handle: handle)) {
            if case .name(_, let entries) = $0 { entries } else { nil }
        }
    }

    public func remove(_ path: [UInt8]) async throws(FilesError) {
        try await status(.remove(path: path))
    }

    public func mkdir(_ path: [UInt8], attributes: SFTPAttributes = SFTPAttributes()) async throws(FilesError)
    {
        try await status(.mkdir(path: path, attributes: attributes))
    }

    public func rmdir(_ path: [UInt8]) async throws(FilesError) {
        try await status(.rmdir(path: path))
    }

    /// The canonical absolute form of `path`.
    public func realpath(_ path: [UInt8]) async throws(FilesError) -> [UInt8] {
        try await reply(to: .realpath(path: path)) {
            if case .name(_, let entries) = $0 { entries.first?.name } else { nil }
        }
    }

    /// SFTP's own rename, which fails when `to` exists.
    public func rename(from: [UInt8], to: [UInt8]) async throws(FilesError) {
        try await status(.rename(from: from, to: to))
    }

    /// `posix-rename@openssh.com`: replaces `to`.
    public func posixRename(from: [UInt8], to: [UInt8]) async throws(FilesError) {
        guard extensions.posixRename else { throw .unsupported }
        try await status(.posixRename(from: from, to: to))
    }

    public func statvfs(_ path: [UInt8]) async throws(FilesError) -> SFTPSpace {
        guard extensions.statvfs else { throw .unsupported }
        return try await extended(.statvfs(path: path), SFTPSpace.decode)
    }

    /// Flushes an open file to disk, within 60 s plus 1 s per 16 MiB of `bytesWritten`.
    public func fsync(handle: [UInt8], bytesWritten: UInt64) async throws(FilesError) {
        guard extensions.fsync else { throw .unsupported }
        let limit = Self.replyLimit + .seconds(bytesWritten / (16 << 20))
        try await status(.fsync(handle: handle), limit: limit)
    }

    public func limits() async throws(FilesError) -> SFTPLimits {
        guard extensions.limits else { throw .unsupported }
        return try await extended(.limits, SFTPLimits.decode)
    }

    // MARK: Reply kinds

    /// What `value` finds in the reply; nil at the end of the file or folder.
    private func untilEndOfFile<T>(
        _ request: SFTPRequest, _ value: (SFTPReply) -> T?
    ) async throws(FilesError) -> T? {
        let reply = try await send(request)
        if case .status(_, .endOfFile) = reply { return nil }
        guard let found = value(reply) else { throw await failure(reply) }
        return found
    }

    /// What `value` finds in the reply to `request`; anything else is `failure(_:)`.
    private func reply<T>(
        to request: SFTPRequest, limit: Duration = replyLimit, _ value: (SFTPReply) -> T?
    ) async throws(FilesError) -> T {
        let reply = try await send(request, limit: limit)
        guard let found = value(reply) else { throw await failure(reply) }
        return found
    }

    private func status(_ request: SFTPRequest, limit: Duration = replyLimit) async throws(FilesError) {
        try await reply(to: request, limit: limit) { if case .status(_, .ok) = $0 { () } else { nil } }
    }

    private func handle(_ request: SFTPRequest) async throws(FilesError) -> [UInt8] {
        try await reply(to: request) { if case .handle(_, let handle) = $0 { handle } else { nil } }
    }

    private func attributes(_ request: SFTPRequest) async throws(FilesError) -> SFTPAttributes {
        try await reply(to: request) {
            if case .attributes(_, let attributes) = $0 { attributes } else { nil }
        }
    }

    private func extended<T>(
        _ request: SFTPRequest, _ decode: ([UInt8]) throws(SFTPError) -> T
    ) async throws(FilesError) -> T {
        let body = try await reply(to: request) {
            if case .extendedReply(_, let body) = $0 { body } else { nil }
        }
        do { return try decode(body) } catch { throw await unexpected() }
    }

    /// A STATUS's error. Shapes are checked as replies arrive, so nothing else gets here; if it
    /// did, the session ends.
    private func failure(_ reply: SFTPReply) async -> FilesError {
        if case .status(_, let code) = reply, code != .ok { return FilesError(status: code) }
        return await unexpected()
    }
}
