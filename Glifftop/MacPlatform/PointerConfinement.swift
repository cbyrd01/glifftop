import AppKit
import GliffInput

/// Holds the Mac pointer still over a video view (Capture mode, confined): the hidden cursor
/// is warped to the view's centre and cut off from the mouse, and every mouse event of the app
/// goes to `onEvent` instead of being hit-tested, with its delta (points, `y` growing down), so
/// motions can move a virtual pointer.
@MainActor final class PointerConfinement {
    private static let events: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel,
    ]

    private weak var view: VideoNSView?
    private let onEvent: (NSEvent, _ delta: (dx: Double, dy: Double)) -> Void
    private var monitor: Any?
    /// The start warp's displacement in points (`y` growing down, as NSEvent's deltas) and when
    /// it happened (`NSEvent.timestamp`'s clock), until a motion carries it (`StartWarp`) or
    /// `warpWindow` passes: motions queued before the warp may come first.
    private var warp: (dx: Double, dy: Double, at: TimeInterval)?
    private static let warpWindow: TimeInterval = 0.25

    init(view: VideoNSView, onEvent: @escaping (NSEvent, _ delta: (dx: Double, dy: Double)) -> Void) {
        self.view = view
        self.onEvent = onEvent
    }

    isolated deinit { stop(warpTo: nil) }

    var isActive: Bool { monitor != nil }

    /// Warps the pointer to the view's centre, holds it there, and takes every mouse event. Not
    /// when the centre is off every display or another window covers it there: clicks would
    /// reach what is under it.
    func start() {
        guard monitor == nil, let view, let centre = view.centreOnScreen,
            NSScreen.screens.contains(where: { NSMouseInRect(centre, $0.frame, false) }),
            view.isFrontmost(onScreen: centre)
        else { return }
        let from = ScreenCoordinates.global(fromAppKit: NSEvent.mouseLocation)
        let to = ScreenCoordinates.global(fromAppKit: centre)
        CGWarpMouseCursorPosition(to)
        CGAssociateMouseAndMouseCursorPosition(0)
        warp = (Double(to.x - from.x), Double(to.y - from.y), ProcessInfo.processInfo.systemUptime)
        monitor = NSEvent.addLocalMonitorForEvents(matching: Self.events) { [weak self] event in
            guard let self else { return event }
            take(event)
            return nil
        }
    }

    /// Lets the pointer go: at `point` (AppKit screen coordinates) when given, joined to the
    /// mouse again straight after, so no frozen interval follows.
    func stop(warpTo point: NSPoint?) {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        warp = nil
        if let point { CGWarpMouseCursorPosition(ScreenCoordinates.global(fromAppKit: point)) }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func take(_ event: NSEvent) {
        var delta = (dx: Double(event.deltaX), dy: Double(event.deltaY))
        if let warp, event.isPointerMotion {
            if event.timestamp - warp.at > Self.warpWindow {
                self.warp = nil
            } else if let hand = StartWarp.handMotion(delta: delta, warp: (warp.dx, warp.dy)) {
                self.warp = nil
                delta = hand
            }
        }
        onEvent(event, delta)
    }
}
