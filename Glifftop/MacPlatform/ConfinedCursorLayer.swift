import AppKit
import QuartzCore

/// The confined pointer's sprite (Capture mode): the Mac cursor is frozen and hidden, so this
/// layer over the picture draws the pointer where the virtual one is, at event rate, ahead of
/// the picture. Never Liquid Glass: it isn't chrome.
@MainActor final class ConfinedCursorLayer {
    /// The sprite, a sublayer of the video view's layer (view points, `y` growing up).
    let layer = CALayer()
    /// The cursor and backing scale whose image the layer holds.
    private var shown: (cursor: NSCursor, scale: CGFloat)?

    init() {
        layer.isHidden = true
        layer.zPosition = 1
        // It follows the hand: no implicit animation of any of it.
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
    }

    /// `cursor`'s image with its hotspot at `point` (view points), at `scale` backing pixels to
    /// the point.
    func show(_ cursor: NSCursor, at point: CGPoint, scale: CGFloat) {
        if shown?.cursor !== cursor || shown?.scale != scale {
            shown = (cursor, scale)
            layer.contents = cursor.image.layerContents(forContentsScale: scale)
            layer.contentsScale = scale
        }
        let size = cursor.image.size
        // The hotspot is from the image's top-left; the layer's origin is its bottom-left.
        layer.frame = CGRect(
            x: point.x - cursor.hotSpot.x, y: point.y - (size.height - cursor.hotSpot.y), width: size.width,
            height: size.height)
        layer.isHidden = false
    }

    func hide() {
        layer.isHidden = true
    }
}
