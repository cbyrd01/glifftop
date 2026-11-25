/// The ⌘Q guard's timing, from values: a first press shows "Hold ⌘Q to Quit", holding 1 s
/// quits, letting go early leaves the message 1.5 s, and a fresh press while it shows quits.
/// Times are `Duration`s since an origin the caller picks; it has no clock, and says when it
/// next needs a `tick`.
public struct QuitHold: Sendable {
    public enum Action: Sendable, Equatable {
        case none
        /// Show the message.
        case show
        /// Quit now; the message goes with the app (hide it too if the quit is cancelled).
        case quit
        /// Fade the message out.
        case hide
    }

    /// How long ⌘ and the key must stay down.
    public static let hold: Duration = .seconds(1)
    /// How long the message stays after an early let-go.
    public static let linger: Duration = .milliseconds(1500)
    /// The message's fade, for the panel.
    public static let fade: Duration = .milliseconds(200)

    private enum State: Sendable {
        case idle
        case holding(since: Duration)
        case lingering(until: Duration)
    }

    private var state = State.idle

    public init() {}

    public var isShowing: Bool {
        if case .idle = state { false } else { true }
    }

    /// When the next `tick` is due, or nil while idle.
    public var nextDeadline: Duration? {
        switch state {
        case .idle: nil
        case .holding(let since): since + Self.hold
        case .lingering(let until): until
        }
    }

    /// A guarded ⌘ key-down. A repeat changes nothing.
    public mutating func keyDown(isRepeat: Bool, at time: Duration) -> Action {
        guard !isRepeat else { return .none }
        switch state {
        case .idle:
            state = .holding(since: time)
            return .show
        case .holding, .lingering:
            state = .idle
            return .quit
        }
    }

    /// The key or ⌘ let go: before the hold's second, the message lingers; after it (the
    /// timer ran late), the hold was met and it quits.
    public mutating func keyUp(at time: Duration) -> Action {
        guard case .holding(let since) = state else { return .none }
        guard time < since + Self.hold else {
            state = .idle
            return .quit
        }
        state = .lingering(until: time + Self.linger)
        return .none
    }

    /// The timer. `keysDown` is the keys' real state, read when the hold is due.
    public mutating func tick(at time: Duration, keysDown: Bool) -> Action {
        switch state {
        case .idle: return .none
        case .holding(let since):
            guard time >= since + Self.hold else { return .none }
            guard keysDown else {
                state = .lingering(until: time + Self.linger)
                return .none
            }
            state = .idle
            return .quit
        case .lingering(let until):
            guard time >= until else { return .none }
            state = .idle
            return .hide
        }
    }
}
