import AppKit
import GliffClipboard
import os

/// Puts the remote's offer on the Mac pasteboard: one item with its text, HTML and
/// PNG, each type fetched only when a Mac app pastes it (`PasteProvider`). A remote password
/// is marked concealed, so Mac clipboard managers skip it. Files aren't shared.
enum RemotePasteboard {
    private static let log = Logger(subsystem: "io.github.cbyrd01.Glifftop", category: "clipboard")

    /// The pasteboard's `changeCount` after writing, or nil if the offer holds nothing the Mac
    /// can take (files alone, or only other types): the pasteboard is left as it is. Once
    /// cleared, the pasteboard is ours even if the write fails.
    static func write(_ offer: RemoteClipboardOffer, provider: PasteProvider) -> Int? {
        let types = PasteboardTypes.types(forRemote: offer.mimeTypes)
        guard !types.isEmpty else { return nil }
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: types) else { return nil }
        if offer.isPassword { item.setData(Data(), forType: PasteboardTypes.concealed) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.writeObjects([item]) { log.error("remote clipboard not written to the pasteboard") }
        return pasteboard.changeCount
    }
}
