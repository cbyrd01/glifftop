public import GliffInput
import Synchronization

/// The app's barrier between sessions: after one session sends a modifier key's release, every
/// other session's input waits until that session's server has handled it. Hyprland combines
/// the modifiers of every keyboard, and each session's input reaches it by its own path, so
/// another session's next key could otherwise land before the release and be read with the
/// modifier held. A server busy encoding reads its input late, so no fixed time is enough.
///
/// The releasing session sends a Ping behind the release. Upstream's server handles a
/// session's messages in order on one task, handing each input to its input thread before it
/// answers a Ping: the Pong says the release has been handed on. What waits goes `settle`
/// after that answer, or `limit` after the release goes if no answer comes.
public final class InputBarrier: Sendable {
    /// How long after a release's answer another session's input still waits: the server's
    /// input thread and the compositor act on it.
    public static let settle = Duration.milliseconds(10)
    /// The longest another session's input waits for a release's answer, from when the release
    /// goes: a stalled link never holds the other tabs for long.
    public static let limit = Duration.milliseconds(250)

    /// A session, as the barrier tells them apart: each one new, so a session made where
    /// another has just gone is never taken for it.
    public struct Sender: Hashable, Sendable {
        private static let next = Atomic<UInt64>(0)
        private let id: UInt64

        public init() { id = Self.next.add(1, ordering: .relaxed).newValue }
    }

    /// One modifier release, as what waits for it names it: its session's releases are numbered
    /// in the order they go.
    public struct Release: Hashable, Sendable {
        public let sender: Sender
        let number: UInt64
    }

    /// What another session's input waits for, and how long at most from now.
    public struct Wait: Equatable, Sendable {
        public let release: Release
        public let left: Duration
    }

    /// What `wait(before:from:goesAfter:)` decided: what `input` waits for, and the release it
    /// recorded, if `input` is one.
    public struct Decision: Sendable {
        public let wait: Wait?
        public let recorded: Release?
    }

    /// One session's releases: the latest, and the latest answered.
    private struct Releases {
        var latest: UInt64 = 0
        /// When the latest goes; its limit counts from then.
        var goes: Duration = .zero
        var answered: (number: UInt64, at: Duration)?
        /// What waits for an answer still to come: the release it waits for, and how to tell it.
        var waiters: [(number: UInt64, heard: @Sendable (Duration) -> Void)] = []

        func isAnswered(_ number: UInt64) -> Bool { (answered?.number ?? 0) >= number }

        /// When what waits for release `number` may go: `settle` after its answer, or `limit`
        /// after the latest goes (no earlier than it would).
        func end(of number: UInt64) -> Duration {
            if let answered, isAnswered(number) { return answered.at + InputBarrier.settle }
            return goes + InputBarrier.limit
        }
    }

    private struct State {
        /// The last modifier release, of any session.
        var last: Release?
        var releases: [Sender: Releases] = [:]
        var next: UInt64 = 0
    }

    /// The clock the sessions' queues hold on.
    let clock: any Clock<Duration>
    /// Time on the clock since the barrier was made.
    private let elapsed: @Sendable () -> Duration
    private let state = Mutex(State())

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
        elapsed = clock.stopwatch()
    }

    /// What `input` from `sender` must wait for: another session's last modifier release, until
    /// its answer, or nil. A modifier release is recorded at when it goes, before its session's
    /// gate judges it: `goesAfter` says how long after now that is, given its wait here (its own
    /// queue may hold it longer: `InputQueue.delay(holding:)`). One the gate then drops (its
    /// press never went) is still answered, which costs only that round trip.
    public func wait(
        before input: InputMessage, from sender: Sender, goesAfter: (Duration) -> Duration = { $0 }
    ) -> Decision {
        let now = elapsed()
        return state.withLock { state in
            var wait: Wait?
            if let last = state.last, last.sender != sender, let releases = state.releases[last.sender] {
                let end = releases.end(of: last.number)
                if now < end { wait = Wait(release: last, left: end - now) }
            }
            guard case .key(let code, false) = input, MacKeyTranslator.modifierCodes.contains(code) else {
                return Decision(wait: wait, recorded: nil)
            }
            // Sessions whose releases hold no one any more are forgotten.
            state.releases = state.releases.filter {
                $0.key == sender || now < $0.value.end(of: $0.value.latest)
            }
            state.next += 1
            var releases = state.releases[sender] ?? Releases()
            // It goes after this session's own release still held.
            releases.goes = max(now + goesAfter(wait?.left ?? .zero), releases.goes)
            releases.latest = state.next
            state.releases[sender] = releases
            let release = Release(sender: sender, number: state.next)
            state.last = release
            return Decision(wait: wait, recorded: release)
        }
    }

    /// `release`'s server has answered a Ping sent behind it: what waits for it goes `settle`
    /// from now.
    public func answered(_ release: Release) {
        let now = elapsed()
        let heard: [@Sendable (Duration) -> Void] = state.withLock { state in
            guard var releases = state.releases[release.sender], !releases.isAnswered(release.number) else {
                return []
            }
            releases.answered = (release.number, now)
            let done = releases.waiters.filter { $0.number <= release.number }.map(\.heard)
            releases.waiters.removeAll { $0.number <= release.number }
            state.releases[release.sender] = releases
            return done
        }
        for tell in heard { tell(Self.settle) }
    }

    /// Tells `heard` how long what waits for `release` has left once it is answered: at once if
    /// it has been, or if its session's releases are forgotten.
    public func whenAnswered(_ release: Release, _ heard: @escaping @Sendable (Duration) -> Void) {
        let now = elapsed()
        let left: Duration? = state.withLock { state in
            guard var releases = state.releases[release.sender] else { return .zero }
            guard releases.isAnswered(release.number) else {
                releases.waiters.append((release.number, heard))
                state.releases[release.sender] = releases
                return nil
            }
            return max(releases.end(of: release.number) - now, .zero)
        }
        if let left { heard(left) }
    }
}
