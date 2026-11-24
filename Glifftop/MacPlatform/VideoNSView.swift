import AppKit
import GliffInput
import GliffSession
import GliffVideo
import Metal
import QuartzCore
import os

/// The remote picture: a `CAMetalLayer` that a display link draws into, only when the slot has
/// a new picture, the drawable changed size or the picture's view box changed, and only while
/// the window is visible. Each picture carries the remote view box it fills. Never Liquid Glass.
/// Its mouse and scroll events go to `onPointer` in remote coordinates, mapped over the picture
/// as it is drawn; over the picture the pointer looks as `RemoteCursor` says
/// (`VideoNSView+Cursor.swift`; the state it shares is internal for that file, not an interface).
final class VideoNSView: NSView {
    /// What the window is fitted to (the session's monitor, or the screen for a virtual one),
    /// and View ▸ Actual Size's count.
    struct Fit: Equatable {
        var sizing: WindowSizing
        var request: Int
    }

    private static let logger = Logger(subsystem: "me.cbyrd.Glifftop", category: "video")
    static let cursorLogger = Logger(subsystem: "me.cbyrd.Glifftop", category: "cursor")

    /// Fits the window when it changes (and once the view is in a window). Each session gets its
    /// own view: StreamingView exists only while streaming. The sizing is the session's, set
    /// once, so a later view from the server never resizes the window; a reconnect's (with
    /// `fitsWindow` off) changes only what Actual Size fits.
    var fit: Fit? {
        didSet {
            guard fit != oldValue, fitsWindow || fit?.request != oldValue?.request else { return }
            fitWindow()
        }
    }

    /// Points under the picture in the window's content (the status bar). Counted when the
    /// window is fitted; once fitted, a change grows or shrinks a mirror's window by as much,
    /// and leaves a virtual screen's (the remote follows the picture).
    var extraHeight: CGFloat = 0 {
        didSet {
            guard extraHeight != oldValue, fitted, !sharesWindow, let window, case .monitor = fit?.sizing
            else {
                return
            }
            let delta = extraHeight - oldValue
            // Not inside SwiftUI's update pass, as `fitWindow`.
            Task { WindowSizer.grow(window, by: delta) }
        }
    }

    /// False for a reconnect's session: its first fit leaves the window at the size it has
    /// (a later one, Actual Size say, fits as usual).
    var fitsWindow = true

    /// The window has other tabs, whose size it shares: the session never sizes it. A mirror
    /// left alone in it (torn off, its other tabs closed) is fitted again.
    var sharesWindow = false {
        didSet {
            guard oldValue, !sharesWindow, fitted, case .monitor = fit?.sizing else { return }
            fitWindow()
        }
    }

    /// View ▸ Scale to Fit: a picture smaller than the view is scaled up to fill it.
    var scaleToFit = false

    /// The drawable's size in pixels and the backing scale, for the remote screen to match:
    /// reported once the window has been fitted for the session, then on every change.
    var onTarget: (PixelSize, Double) -> Void = { _, _ in }

    /// A pointer event over the picture, in remote coordinates: true when it was for the remote
    /// (or took input back), and so goes no further on the Mac.
    var onPointer: (PointerEvent) -> Bool = { _ in false }

    /// The pointer's look over the picture.
    let cursor = RemoteCursor()

    private let slot: PictureSlot
    /// The cursor shape's generation and size last seen by the display link.
    private var cursorSeen: (generation: UInt64?, pointsPerPixel: Double?) = (nil, nil)
    /// A cursor change `refreshCursor` couldn't show yet: the display link tries again.
    var cursorPending = false
    /// A button went down on the picture and isn't up yet: its release checks the cursor again.
    var pressedHere = false
    /// The picture's cursor last shown, so that only it is taken back (`CursorClaim`).
    var claim = CursorClaim<NSCursor>()
    /// Between the app's `willResignActive` and its next `didBecomeActive`: it still counts as
    /// active, but the picture's cursor mustn't come back.
    var focusLeaving = false
    private let renderer: PictureRenderer
    private let queue: (any MTLCommandQueue)?
    private let metalLayer = CAMetalLayer()
    private var tracker = RedrawTracker()
    private var displayLink: CADisplayLink?
    /// A failing draw is retried every frame: log it once per run of failures.
    private var drawFailing = false
    /// Set once the window has been fitted for the session: no target before, as
    /// the machines window isn't the session's.
    private var fitted = false
    /// The target last reported to `onTarget`.
    private var reported: (size: PixelSize, backingScale: Double)?

    init(slot: PictureSlot, renderer: PictureRenderer) {
        self.slot = slot
        self.renderer = renderer
        queue = renderer.device.makeCommandQueue()
        super.init(frame: .zero)
        // Without a queue nothing is ever drawn: say why the picture stays black.
        if queue == nil { Self.logger.error("no Metal command queue: the video view can't draw") }
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        // While a live resize waits for the next draw, keep the last frame's proportions.
        metalLayer.contentsGravity = .resizeAspect
        wantsLayer = true
        // Motion while the window is key, over whatever part of the view is visible (it follows
        // resizes by itself). Not while the window is in the background: nothing is captured then.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [
                    .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect,
                    .enabledDuringMouseDrag,
                ],
                owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("VideoNSView is made in code") }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override var isOpaque: Bool { true }

    // A click that only brings the window forward isn't the remote's: the window
    // comes to the front and captures, and the next click is the remote's.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    // AppKit hands each kind of mouse event to its own method; all of them go to `pointer`.
    // An event that wasn't for the remote goes on as NSView's would.
    override func mouseMoved(with event: NSEvent) {
        // The tracking area reports motion under the overlays and other windows too: over one
        // of them (whatever the hit test finds instead of this view) nothing is sent, and the
        // picture's cursor is given back. A drag comes through the *Dragged methods instead,
        // and keeps sending even outside, clamped to the picture's edge.
        guard followPointer(event) else { return super.mouseMoved(with: event) }
        if !pointer(event) { super.mouseMoved(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        pressedHere = true
        if !pointer(event) { super.mouseDown(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        buttonUp()
        if !pointer(event) { super.mouseUp(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        followPointer(event)
        if !pointer(event) { super.mouseDragged(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        pressedHere = true
        if !pointer(event) { super.rightMouseDown(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) {
        buttonUp()
        if !pointer(event) { super.rightMouseUp(with: event) }
    }
    override func rightMouseDragged(with event: NSEvent) {
        followPointer(event)
        if !pointer(event) { super.rightMouseDragged(with: event) }
    }
    override func otherMouseDown(with event: NSEvent) {
        pressedHere = true
        if !pointer(event) { super.otherMouseDown(with: event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        buttonUp()
        if !pointer(event) { super.otherMouseUp(with: event) }
    }
    override func otherMouseDragged(with event: NSEvent) {
        followPointer(event)
        if !pointer(event) { super.otherMouseDragged(with: event) }
    }
    override func scrollWheel(with event: NSEvent) { if !pointer(event) { super.scrollWheel(with: event) } }

    // Off the picture (an overlay, another window over it), AppKit and what is there decide.
    override func cursorUpdate(with event: NSEvent) {
        guard isHit(at: event.locationInWindow) else { return super.cursorUpdate(with: event) }
        showCursor()
    }

    // Leaving the view; overlays are inside (`followPointer` handles them).
    override func mouseExited(with event: NSEvent) { giveBackCursor() }

    // Coming back in, the picture's cursor. Not sent during a drag, even with
    // `.enabledDuringMouseDrag` (checked by hand): `followPointer` covers a drag.
    override func mouseEntered(with event: NSEvent) {
        if NSEvent.pressedMouseButtons == 0 { refreshCursor() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // The picture is going (the session ended): not the remote's shape or the hidden cursor
        // left under a pointer that hasn't moved, even in a live resize (nothing would after).
        if newWindow == nil { giveBackCursor(evenInLiveResize: true) }
        // The focus observers go with the window; `viewDidMoveToWindow` adds them again.
        for name in [
            NSWindow.didResignKeyNotification, NSApplication.willResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification,
        ] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
    }

    /// Points per remote view pixel at the picture's size on screen; nil without a picture.
    func cursorPointsPerPixel() -> Double? {
        guard let view = slot.latest?.picture.view, let window else { return nil }
        let fit = VideoFit.viewport(picture: view, drawable: drawableSize(), scaleToFit: scaleToFit)
        return CursorImage.pointsPerPixel(
            rectWidth: Double(fit.width), viewWidth: view.width, backingScale: window.backingScaleFactor)
    }

    /// Hands `event` to `onPointer` at its remote position; false when there's no picture to
    /// map it over, or it wasn't for the remote.
    private func pointer(_ event: NSEvent) -> Bool {
        guard let position = remotePosition(of: event), let pointerEvent = PointerEvent(event, at: position)
        else {
            return false
        }
        return onPointer(pointerEvent)
    }

    /// Where `event` is over the latest picture, in the remote's logical coordinates.
    private func remotePosition(of event: NSEvent) -> (x: Double, y: Double)? {
        remotePosition(ofWindowPoint: event.locationInWindow)?.position
    }

    /// Where a window `point` is over the latest picture, in the remote's logical coordinates,
    /// and whether it is inside the picture drawn: the point in drawable pixels from the
    /// top-left, mapped through the fit the renderer draws with (`VideoFit.viewport` of the
    /// picture's view box in this drawable).
    private func remotePosition(ofWindowPoint windowPoint: NSPoint) -> (
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
    private func pictureRect(for picture: GliffVideo.Picture, in drawable: PixelSize) -> PictureRect {
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

    /// The drawable's size: the view's bounds in backing pixels.
    private func drawableSize() -> PixelSize { backingPixels() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard let window else { return }
        // A view moved into a window under a resting pointer shows its cursor without motion.
        cursorPending = true
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(focusLost), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(
            self, selector: #selector(focusLost), name: NSApplication.willResignActiveNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(focusGained), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(
            self, selector: #selector(focusGained), name: NSApplication.didBecomeActiveNotification,
            object: nil)
        let link = displayLink(
            target: VideoDisplayLinkTarget(self), selector: #selector(VideoDisplayLinkTarget.step))
        link.add(to: .main, forMode: .common)
        displayLink = link
        fitWindow()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 1
    }

    /// One display-link tick (`VideoDisplayLinkTarget`): the cursor, then the picture.
    func step() {
        // A new shape, or the picture's size on screen changing (the first picture, Actual Size,
        // another screen), shows under a resting pointer without waiting for motion.
        let seen = (generation: cursor.generation, pointsPerPixel: cursorPointsPerPixel())
        if seen != cursorSeen || cursorPending {
            cursorSeen = seen
            refreshCursor()
        }
        let size = drawableSize()
        reportTarget(size)
        let latest = slot.latest
        // A covered or minimised window gets no drawables: nextDrawable() would block the main
        // thread for its timeout on every picture. The tracker redraws once it's visible again.
        guard window?.occlusionState.contains(.visible) == true, size.width > 0, size.height > 0,
            let latest,
            // Read once: an update after this is newer than what's recorded, so it redraws.
            case let view = latest.picture.view,
            tracker.needsDraw(
                generation: latest.generation, drawable: size, view: view, scaleToFit: scaleToFit),
            let queue
        else { return }
        let drawableSize = CGSize(width: size.width, height: size.height)
        if metalLayer.drawableSize != drawableSize { metalLayer.drawableSize = drawableSize }
        guard let drawable = metalLayer.nextDrawable(), let commandBuffer = queue.makeCommandBuffer() else {
            return
        }
        do {
            // The renderer holds the picture until the command buffer completes.
            try renderer.encode(
                latest.picture, into: drawable.texture, commandBuffer: commandBuffer, scaleToFit: scaleToFit)
        } catch {
            if !drawFailing {
                Self.logger.error(
                    "drawing the picture failed: \(String(describing: error), privacy: .public)")
            }
            drawFailing = true
            return
        }
        drawFailing = false
        commandBuffer.present(drawable)
        commandBuffer.commit()
        tracker.drew(generation: latest.generation, drawable: size, view: view, scaleToFit: scaleToFit)
    }

    /// Tells `onTarget` of a new drawable size or backing scale, once fitted. Every tick, so
    /// a live resize, full screen and another display are all seen; the session sends only
    /// once a target settles.
    private func reportTarget(_ size: PixelSize) {
        guard fitted, let window, size.width > 0, size.height > 0 else { return }
        let target = (size: size, backingScale: Double(window.backingScaleFactor))
        if let reported, reported == target { return }
        reported = target
        onTarget(target.size, target.backingScale)
    }

    private func fitWindow() {
        guard let window, let fit else { return }
        guard fitsWindow || fitted, !sharesWindow else {
            fitted = true
            return
        }
        // Not inside SwiftUI's update pass: resizing the window there re-enters its layout.
        Task {
            switch fit.sizing {
            case .monitor(let size): WindowSizer.fit(window, view: size, extraHeight: extraHeight)
            case .fillScreen: WindowSizer.fill(window)
            }
            // Laid out now, so the next tick's drawable is the fitted one, not the machines window's.
            window.layoutIfNeeded()
            fitted = true
        }
    }
}
