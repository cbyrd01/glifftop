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
    func remotePosition(ofWindowPoint windowPoint: NSPoint) -> (
        position: (x: Double, y: Double), inside: Bool
    )? {
        guard let layout = layout() else { return nil }
        let point = convert(windowPoint, from: nil)
        // Not flipped: AppKit's y grows upward, the drawable's downward.
        let x = (point.x - bounds.minX) * layout.pixelsPerPoint.x
        let y = (bounds.maxY - point.y) * layout.pixelsPerPoint.y
        let rect = layout.rect
        let inside = x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
        guard
            let position = PointerMapper.remote(
                x: x, y: y, in: rect, geometry: layout.picture.pointerGeometry)
        else { return nil }
        return (position, inside)
    }

    /// Whether a window `location` is over the picture as drawn (not the bars beside it) and
    /// nothing covers it there (`isHit`).
    func isOverPicture(at location: NSPoint) -> Bool {
        isHit(at: location) && isInsidePicture(at: location)
    }

    /// Whether a window `location` lies inside the picture as drawn, covered or not.
    func isInsidePicture(at location: NSPoint) -> Bool {
        remotePosition(ofWindowPoint: location)?.inside == true
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
        guard isFrontmost(onScreen: mouse),
            let mapped = remotePosition(ofWindowPoint: window.convertPoint(fromScreen: mouse)), mapped.inside
        else { return nil }
        return mapped.position
    }

    /// The view's frame in AppKit screen coordinates; nil outside a window.
    var frameOnScreen: NSRect? {
        window?.convertToScreen(convert(bounds, to: nil))
    }

    /// The centre of the view in AppKit screen coordinates: where a confined pointer freezes.
    var centreOnScreen: NSPoint? {
        frameOnScreen.map { NSPoint(x: $0.midX, y: $0.midY) }
    }

    /// The latest picture's pointer geometry; nil without a picture.
    var geometry: PictureGeometry? { slot.latest?.picture.pointerGeometry }

    /// A remote logical point over the picture as drawn, in AppKit screen coordinates, clamped
    /// into the picture; nil without a picture or a window.
    func screenPoint(ofRemote remote: (x: Double, y: Double)) -> NSPoint? {
        guard let window, let point = viewPoint(ofRemote: remote) else { return nil }
        return window.convertPoint(toScreen: convert(point, to: nil))
    }

    /// A remote logical point over the picture as drawn, in the view's points, clamped into the
    /// picture; nil without a picture.
    func viewPoint(ofRemote remote: (x: Double, y: Double)) -> NSPoint? {
        guard let layout = layout(), layout.rect.width > 0, layout.rect.height > 0,
            let local = PointerMapper.local(
                x: remote.x, y: remote.y, in: layout.rect, geometry: layout.picture.pointerGeometry)
        else { return nil }
        let rect = layout.rect
        // Half a pixel inside each edge: still on the picture once in points.
        let x = min(max(local.x, rect.x + 0.5), rect.x + rect.width - 0.5)
        let y = min(max(local.y, rect.y + 0.5), rect.y + rect.height - 0.5)
        // Drawable pixels from the top-left to the view's points (AppKit's y grows upward).
        return NSPoint(
            x: bounds.minX + x / layout.pixelsPerPoint.x, y: bounds.maxY - y / layout.pixelsPerPoint.y)
    }

    /// A motion of the Mac pointer in points (NSEvent's deltas, `y` growing down) as a remote
    /// logical delta, at the scale the absolute mapping uses; nil without a picture.
    func remoteDelta(ofPoints delta: (dx: Double, dy: Double)) -> (dx: Double, dy: Double)? {
        guard let layout = layout() else { return nil }
        return PointerMapper.remoteDelta(
            dx: delta.dx * layout.pixelsPerPoint.x, dy: delta.dy * layout.pixelsPerPoint.y, in: layout.rect,
            geometry: layout.picture.pointerGeometry)
    }

    /// The latest picture, where it is drawn (drawable pixels) and the drawable's pixels per
    /// view point on each axis; nil without a picture or a size.
    private func layout() -> (
        picture: GliffVideo.Picture, rect: PictureRect, pixelsPerPoint: (x: Double, y: Double)
    )? {
        guard let picture = slot.latest?.picture, bounds.width > 0, bounds.height > 0 else { return nil }
        let drawable = drawableSize()
        guard drawable.width > 0, drawable.height > 0 else { return nil }
        return (
            picture, pictureRect(for: picture, in: drawable),
            (Double(drawable.width) / bounds.width, Double(drawable.height) / bounds.height)
        )
    }

    /// The drawable's size: the view's bounds in backing pixels.
    func drawableSize() -> PixelSize { backingPixels() }
}
