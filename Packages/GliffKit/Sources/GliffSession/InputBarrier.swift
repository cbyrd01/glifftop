public import GliffInput
import Synchronization

/// The app's barrier between sessions: after one session sends a modifier key's release, every
/// other session's input waits until `gap` after it goes. Hyprland combines the modifiers of
/// every keyboard, and each session's input reaches it by its own path, so another session's
/// next key could otherwise land before the release and be read with the modifier held.
public final class InputBarrier: Sendable {
    /// How long after a modifier's release another session's input waits.
    public static let gap = Duration.milliseconds(30)

    /// A session, as the barrier tells them apart: each one new, so a session made where
    /// another has just gone is never taken for it.
    public struct Sender: Hashable, Sendable {
        private static let next = Atomic<UInt64>(0)
        private let id: UInt64

        public init() { id = Self.next.add(1, ordering: .relaxed).newValue }
    }

    /// The clock the sessions' queues hold on.
    let clock: any Clock<Duration>
    /// Time on the clock since the barrier was made.
    private let elapsed: @Sendable () -> Duration
    /// The last modifier release: the session that sent it, and when it goes.
    private let last = Mutex<(sender: Sender, at: Duration)?>(nil)

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
        elapsed = clock.stopwatch()
    }

    /// How long `input` from `sender` must wait: until `gap` after another session's last
    /// modifier release, or nil. A modifier release is recorded at when it goes, before its
    /// session's gate judges it: `goesAfter` says how long after now that is, given its wait
    /// here (its own queue may hold it longer: `InputQueue.delay(holding:)`). One the gate then
    /// drops (its press never went) still holds the others for `gap`, which costs only that
    /// wait.
    public func wait(
        before input: InputMessage, from sender: Sender, goesAfter: (Duration) -> Duration = { $0 }
    ) -> Duration? {
        let now = elapsed()
        return last.withLock { last in
            var wait: Duration?
            if let (other, at) = last, other != sender, now < at + Self.gap {
                wait = at + Self.gap - now
            }
            if case .key(let code, false) = input, MacKeyTranslator.modifierCodes.contains(code) {
                var goes = now + goesAfter(wait ?? .zero)
                // It goes after this session's own release still held.
                if let (own, at) = last, own == sender { goes = max(goes, at) }
                last = (sender, goes)
            }
            return wait
        }
    }
}
