import GliffSFTP

/// What a server allows a batch, read once per batch.
struct TransferSettings {
    /// The most bytes a READ asks for, or a WRITE carries.
    var block = Pipeline.blockSize
    var filesAtOnce = FolderFill.filesAtOnce
    /// Whether finished files are flushed with `fsync@openssh.com`.
    var flush = false

    /// Reads the server's limits, when it offers them: `chunk` is the READ or WRITE one. One
    /// handle is left for browsing.
    static func read(
        on session: SFTPSession, chunk: KeyPath<SFTPLimits, UInt32>
    ) async throws(FilesError) -> TransferSettings {
        var settings = TransferSettings(flush: session.extensions.fsync)
        guard session.extensions.limits else { return settings }
        let limits = try await session.limits()
        settings.block = min(Pipeline.blockSize, limits[keyPath: chunk])
        if limits.openHandles != 0 {
            settings.filesAtOnce = Int(
                clamping: max(1, min(limits.openHandles - 1, UInt64(FolderFill.filesAtOnce))))
        }
        return settings
    }
}
