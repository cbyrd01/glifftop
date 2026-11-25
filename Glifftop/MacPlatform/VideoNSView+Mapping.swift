import AppKit
import GliffInput
import GliffVideo

/// Where points over the view fall on the picture and on the remote screen.
extension VideoNSView {
    /// Points per remote view pixel at the picture's size on screen; nil without a picture.
    func cursorPointsPerPixel() -> Double? {
        guard let view = slot.latest?.picture.view, let window else { return nil }
        let fit = VideoFit.viewport(picture: view, drawable: drawableSize(), scaleToFit: scaleToFit)
        return CursorImage.pointsPerPixel(
            rectWidth: Double(fit.width), viewWidth: view.width, backingScale: window.backingScaleFactor)
    }

    /// Where `event` is over the latest picture, in the remote's logical coordinates.
    func remotePosition(of event: NSEvent) -> (x: Double, y: Double)? {
        remotePosition(ofWindowPoint: event.locationInWindow)?.position
    }

    /// Where a window `point` is over the latest picture, in the remote's logical coordinates,
    /// and whether it is inside the picture drawn: the point in drawable pixels from the
    /// top-left, mapped through the fit the renderer draws with (`VideoFit.viewport` of the
    /// picture's view box in this drawable).
    fileprivate func remotePosition(ofWindowPoint windowPoint: NSPoint) -> (
        position: (x: Double, y: Double), inside: Bool
    )? {
        guard let picture = slot.latest?.picture, bounds.width > 0, bounds.height > 0 else { return nil }
        let drawable = drawableSize()
        let point = convert(windowPoint, from: nil)
        // Not flipped: AppKit's y grows upward, the drawable's downward.
        let x = (point.x - bounds.minX) * Double(drawable.width) / bounds.width
        let y = (bounds.maxY - point.y) * Double(drawable.height) / bounds.height
        let rect = pictureRect(for: picture, in: drawable)
        let inside = x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
        guard let position = PointerMapper.remote(x: x, y: y, in: rect, geometry: picture.pointerGeometry)
        else { return nil }
        return (position, inside)
    }

    /// The picture's rectangle in drawable pixels, as the renderer draws it.
    fileprivate func pictureRect(for picture: GliffVideo.Picture, in drawable: PixelSize) -> PictureRect {
        let fit = VideoFit.viewport(
            picture: picture.geometry.view, drawable: drawable, scaleToFit: scaleToFit)
        return PictureRect(
            x: Double(fit.x), y: Double(fit.y), width: Double(fit.width), height: Double(fit.height))
    }

    /// The Mac pointer in remote coordinates, when it is over the picture and nothing covers it
    /// there: an activation's first choice of target (`FocusTarget`). Nil otherwise.
    func macPointerOverPicture() -> (x: Double, y: Double)? {
        guard let window else { return nil }
        let mouse = NSEvent.mouseLocation
        guard NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0) == window.windowNumber,
            let mapped = remotePosition(ofWindowPoint: window.convertPoint(fromScreen: mouse)), mapped.inside
        else { return nil }
        return mapped.position
    }

    /// The view's frame in AppKit screen coordinates; nil outside a window.
    var frameOnScreen: NSRect? {
        window?.convertToScreen(convert(bounds, to: nil))
    }

    /// The drawable's size: the view's bounds in backing pixels.
    func drawableSize() -> PixelSize { backingPixels() }
}
