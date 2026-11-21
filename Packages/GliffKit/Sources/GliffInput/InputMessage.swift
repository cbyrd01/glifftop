public import GliffProtocol

/// What the input rules send to the remote, in order. The session turns each into its
/// `ClientMessage`.
public enum InputMessage: Sendable, Equatable {
    /// An evdev key code pressed or released.
    case key(code: UInt32, pressed: Bool)
    /// New XKB keymap text, after the local layout changed.
    case keymap(String)
    /// The pointer at a point in the remote's logical coordinates.
    case pointerMotion(x: Double, y: Double)
    /// An evdev button code (`BTN_LEFT` …) pressed or released.
    case pointerButton(code: UInt32, pressed: Bool)
    /// A scroll: `value` in logical pixels (positive is down or right), `discrete` the wheel
    /// notches, `stop` the end of a gesture.
    case pointerAxis(axis: Axis, value: Double, discrete: Int32?, stop: Bool)

    public var clientMessage: ClientMessage {
        switch self {
        case .key(let code, let pressed): .key(keycode: code, pressed: pressed)
        case .keymap(let text): .keymap(text)
        case .pointerMotion(let x, let y): .pointerMotion(x: x, y: y)
        case .pointerButton(let code, let pressed): .pointerButton(button: code, pressed: pressed)
        case .pointerAxis(let axis, let value, let discrete, let stop):
            .pointerAxis(axis: axis, value: value, discrete: discrete, stop: stop)
        }
    }
}
