/// A pointer event over the picture, as the app reports it, with where it happened in the
/// remote's logical coordinates (the app maps it with `PointerMapper`). `button` carries
/// `NSEvent.buttonNumber`. A button or scroll carries its event's modifier flags (the raw
/// `NSEvent.modifierFlags`, device-dependent bits included, as `MacKeyEvent`'s), so the
/// modifiers held go with it.
public enum PointerEvent: Sendable, Equatable {
    case moved(x: Double, y: Double)
    case button(number: Int, pressed: Bool, x: Double, y: Double, flags: UInt)
    case scroll(ScrollEvent, x: Double, y: Double, flags: UInt)

    /// Where it happened.
    public var position: (x: Double, y: Double) {
        switch self {
        case .moved(let x, let y), .button(_, _, let x, let y, _), .scroll(_, let x, let y, _): (x, y)
        }
    }

    /// The modifier flags it carries: none for motion.
    public var flags: UInt {
        switch self {
        case .moved: 0
        case .button(_, _, _, _, let flags), .scroll(_, _, _, let flags): flags
        }
    }
}
