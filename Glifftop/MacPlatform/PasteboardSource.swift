import AppKit
import CoreGraphics
import GliffClipboard
import ImageIO
import UniformTypeIdentifiers

/// Reads the Mac clipboard when the remote pastes: only the copy the offer was made
/// from (its `changeCount`), a PNG converted from TIFF when that's all there is, at most
/// `ClipboardLimits.maxItem`. The offer itself read only the types.
nonisolated struct PasteboardSource: LocalClipboardSource {
    @concurrent func source(for mime: String, token: Int) async throws(TransferError) -> any ChunkSource {
        let bytes: [UInt8]
        switch await Self.read(mime, token: token) {
        case .bytes(let read):
            bytes = read
        case .tiff(let tiff):
            // Off the main thread: a large picture takes a while.
            guard let png = Self.png(fromTIFF: tiff) else { throw .failed }
            if Task.isCancelled { throw .cancelled }
            bytes = png
        case .failed(let error):
            throw error
        }
        guard UInt64(bytes.count) <= ClipboardLimits.maxItem else { throw .tooLarge }
        return MemorySource(bytes)
    }

    private enum Read: Sendable {
        case bytes([UInt8])
        case tiff(Data)
        case failed(TransferError)
    }

    /// The largest TIFF converted: a picture whose PNG fits `maxItem` is far smaller.
    private static let maxTIFF = 8 * ClipboardLimits.maxItem

    /// The data, only if the pasteboard still holds the offered copy before and after the read
    /// (another app may write in between). A password manager's copy is read too: its offer
    /// carried KDE's marker.
    @MainActor private static func read(_ mime: String, token: Int) -> Read {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == token else { return .failed(.replaced) }
        guard let type = PasteboardTypes.pasteboardType(for: mime) else { return .failed(.failed) }
        let read: Read
        if let data = pasteboard.data(forType: type) {
            read = UInt64(data.count) <= ClipboardLimits.maxItem ? .bytes(Array(data)) : .failed(.tooLarge)
        } else if type == .png, let tiff = pasteboard.data(forType: .tiff) {
            read = UInt64(tiff.count) <= maxTIFF ? .tiff(tiff) : .failed(.tooLarge)
        } else {
            read = .failed(.failed)
        }
        return pasteboard.changeCount == token ? read : .failed(.replaced)
    }

    /// The first picture of a TIFF, as PNG (ImageIO).
    private static func png(fromTIFF tiff: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(tiff as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let out = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                out as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Array(out as Data)
    }
}
