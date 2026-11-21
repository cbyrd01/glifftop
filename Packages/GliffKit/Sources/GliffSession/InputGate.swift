import GliffInput
import GliffProtocol

/// Which input goes to the server. A press, a motion or a scroll only to a live stream: input
/// the remote could act on later, unasked, is dropped. A release only for a press that went,
/// and then always: a key or button held when the link stalls is let go once it returns, and
/// the remote never gets a release it can't pair (upstream forwards every release to the
/// compositor). A scroll's stop is a release too: it goes once its axis has scrolled precisely
/// (a wheel's steps never end with one), and then always, so a gesture cut by a stall still
/// ends. Keymaps always: a dropped one would be lost, as the app sends a layout only when it
/// changes.
struct InputGate {
    /// Keys and buttons whose press went and whose release hasn't.
    private var heldKeys: Set<UInt32> = []
    private var heldButtons: Set<UInt32> = []
    /// Axes scrolled precisely since their last stop.
    private var scrolling: Set<Axis> = []

    mutating func admits(_ input: InputMessage, streaming: Bool, interrupted: Bool) -> Bool {
        let live = streaming && !interrupted
        switch input {
        case .key(let code, let pressed):
            return Self.admits(code, pressed: pressed, live: live, held: &heldKeys)
        case .pointerButton(let code, let pressed):
            return Self.admits(code, pressed: pressed, live: live, held: &heldButtons)
        case .pointerAxis(let axis, _, _, stop: true): return scrolling.remove(axis) != nil
        case .pointerAxis(let axis, _, let discrete, stop: false):
            // A wheel's steps never end with a stop: only a precise scroll opens its axis.
            if live, discrete == nil { scrolling.insert(axis) }
            return live
        case .pointerMotion: return live
        case .keymap: return true
        }
    }

    private static func admits(_ code: UInt32, pressed: Bool, live: Bool, held: inout Set<UInt32>) -> Bool {
        guard pressed else { return held.remove(code) != nil }
        guard live else { return false }
        held.insert(code)
        return true
    }
}
