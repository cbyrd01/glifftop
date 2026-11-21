import GliffProtocol
import os

extension ClipboardBridge {
    /// The remote's new offer, its file list dropped: files aren't shared.
    func remoteOffered(serial: UInt32, mimeTypes: [String], files: [ClipboardFile]) {
        if !files.isEmpty { Self.log.info("remote clipboard offer's files ignored: files aren't shared") }
        let offer = RemoteClipboardOffer(
            serial: serial, mimeTypes: mimeTypes, hasFiles: !files.isEmpty, isFirst: remote == nil)
        remote = offer
        continuation.yield(.remoteOffer(offer))
    }

    /// One type of the remote's offer `serial`, up to `ClipboardLimits.maxItem`; `.replaced` if
    /// a newer offer came since.
    public func fetch(_ mime: String, serial: UInt32, progress: TransferProgress) async throws(TransferError)
        -> [UInt8]
    {
        guard !closed else { throw .connectionEnded }
        guard remote?.serial == serial else { throw .replaced }
        let sink = MemorySink(cap: ClipboardLimits.maxItem)
        _ = try await transfers.fetch(
            .mime(mime), serial: serial, into: sink, cap: ClipboardLimits.maxItem, progress: progress)
        return sink.bytes
    }
}
