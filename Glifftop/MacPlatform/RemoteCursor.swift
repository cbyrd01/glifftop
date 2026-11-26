import AppKit
import GliffInput
import GliffSession

/// The session's cursor shapes, and whether input is captured and the video carries the
/// pointer: the pointer's look over the picture (`CursorLook`), as an `NSCursor`.
final class RemoteCursor {
    /// Another session's shapes: what was made from the last one's doesn't carry over.
    var slot: CursorSlot? { didSet { if slot !== oldValue { made = nil } } }
    var captured = false
    /// The Mac pointer is held over the picture: its cursor is hidden.
    var confined = false
    var videoHasPointer = false
    /// The last shape made into a cursor, and at what size: made again only when either changes.
    private var made: (generation: UInt64, pointsPerPixel: Double, cursor: NSCursor?)?

    /// The latest shape's generation: a new one means the cursor shown may be stale.
    var generation: UInt64? { slot?.latest?.generation }

    /// The cursor to show over the picture; `pointsPerPixel` is nil without a picture to size by.
    func current(pointsPerPixel: Double?) -> NSCursor {
        cursor(captured: captured, confined: confined, pointsPerPixel: pointsPerPixel) ?? hidden
    }

    /// The confined pointer's sprite: the captured look, nil when nothing is to be seen (no
    /// shape to show and the video carries the pointer).
    func sprite(pointsPerPixel: Double?) -> NSCursor? {
        cursor(captured: true, confined: false, pointsPerPixel: pointsPerPixel)
    }

    /// The look `CursorLook` gives as a cursor; nil for `.hidden`.
    private func cursor(captured: Bool, confined: Bool, pointsPerPixel: Double?) -> NSCursor? {
        let latest = slot?.latest
        switch CursorLook.choose(
            captured: captured, videoHasPointer: videoHasPointer, image: latest?.image,
            pointsPerPixel: pointsPerPixel, confined: confined)
        {
        case .arrow: return .arrow
        case .hidden: return nil
        case .shape(let image, let pointsPerPixel):
            let generation = latest?.generation ?? 0
            if let made, made.generation == generation, made.pointsPerPixel == pointsPerPixel {
                return made.cursor ?? .arrow
            }
            let cursor = Self.make(image, pointsPerPixel: pointsPerPixel)
            made = (generation, pointsPerPixel, cursor)
            return cursor ?? .arrow
        }
    }

    /// `image` as a cursor `pointsPerPixel` points to the pixel, its hotspot scaled the same way
    /// (NSCursor's hotspot is from the top-left, as the remote's is). nil if Core Graphics
    /// can't make the image.
    static func make(_ image: CursorImage, pointsPerPixel: Double) -> NSCursor? {
        let (width, height) = (Int(image.width), Int(image.height))
        // B, G, R, A in memory, premultiplied: a little-endian 32-bit ARGB word.
        let info = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: Data(image.bgra) as CFData),
            let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { return nil }
        let size = NSSize(width: Double(width) * pointsPerPixel, height: Double(height) * pointsPerPixel)
        return NSCursor(
            image: NSImage(cgImage: cgImage, size: size),
            hotSpot: NSPoint(x: Double(image.hotX) * pointsPerPixel, y: Double(image.hotY) * pointsPerPixel))
    }

    /// A cursor with nothing to see. Not `NSCursor.hide()`: that hides it everywhere, and counts.
    /// One per view, so a view's `CursorClaim` never takes another window's for its own.
    private let hidden = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }, hotSpot: .zero)
}
