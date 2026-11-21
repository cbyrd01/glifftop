import AppKit
import GliffInput

extension PointerEvent {
    /// A mouse or scroll event of the video view, at `position` (already in remote
    /// coordinates). A drag is motion: the button it drags with is already down. nil for any
    /// other kind of event.
    init?(_ event: NSEvent, at position: (x: Double, y: Double)) {
        let (x, y) = position
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            self = .moved(x: x, y: y)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            self = .button(number: event.buttonNumber, pressed: true, x: x, y: y)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            self = .button(number: event.buttonNumber, pressed: false, x: x, y: y)
        case .scrollWheel:
            let scroll = ScrollEvent(
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                isPrecise: event.hasPreciseScrollingDeltas, phase: ScrollPhase(event.phase),
                isMomentum: !event.momentumPhase.isEmpty)
            self = .scroll(scroll, x: x, y: y)
        default: return nil
        }
    }
}

extension ScrollPhase {
    /// A gesture's phase; a wheel's events have none.
    init(_ phase: NSEvent.Phase) {
        self =
            switch phase {
            case .mayBegin: .mayBegin
            case .began: .began
            case .stationary: .stationary
            case .changed: .changed
            case .ended: .ended
            case .cancelled: .cancelled
            default: .none
            }
    }
}
