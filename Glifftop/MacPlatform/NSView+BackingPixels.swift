import AppKit
import GliffVideo

extension NSView {
    /// The view's bounds in backing pixels, less `height` points taken from its height: what a
    /// video view there draws into. The one rule for the size the remote screen follows.
    func backingPixels(minusHeight height: CGFloat = 0) -> PixelSize {
        var rect = bounds
        rect.size.height = max(rect.height - height, 0)
        let backing = convertToBacking(rect).size
        return PixelSize(width: Int(backing.width.rounded()), height: Int(backing.height.rounded()))
    }
}
