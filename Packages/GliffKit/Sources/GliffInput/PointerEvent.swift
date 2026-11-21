/// A pointer event over the picture, as the app reports it, with where it happened in the
/// remote's logical coordinates (the app maps it with `PointerMapper`). `button` carries
/// `NSEvent.buttonNumber`.
public enum PointerEvent: Sendable, Equatable {
    case moved(x: Double, y: Double)
    case button(number: Int, pressed: Bool, x: Double, y: Double)
    case scroll(ScrollEvent, x: Double, y: Double)

    /// Where it happened.
    public var position: (x: Double, y: Double) {
        switch self {
        case .moved(let x, let y), .button(_, _, let x, let y), .scroll(_, let x, let y): (x, y)
        }
    }
}
