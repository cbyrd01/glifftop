import Synchronization

/// What one reconnect leaves the next, in the same window: its count, while the session it
/// brought back has streamed for less than `steadyTime`. So a host that streams, then drops,
/// each time runs out of tries rather than being tried every second.
public final class ReconnectMemory: Sendable {
    /// How long a reconnected session must stream before its end starts the count over; one
    /// that ends sooner goes on from the last run's count.
    public static let steadyTime = Duration.seconds(30)

    /// A run's count, from `take()`, for `reconnected(with:)` to hand back.
    struct Count {
        var policy: ReconnectPolicy
        /// The `forget()`s before it was taken: one since makes it stale.
        let generation: Int
    }

    private struct State {
        var carried: (policy: ReconnectPolicy, at: Duration)?
        var generation = 0
    }

    /// Time on the clock since the memory was made.
    private let elapsed: @Sendable () -> Duration
    private let state = Mutex(State())

    /// By default on a clock that runs through sleep: a session lost after a night's sleep
    /// streamed all night.
    public init(clock: any Clock<Duration> = ContinuousClock()) {
        elapsed = Self.stopwatch(clock)
    }

    private static func stopwatch<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    /// A connection the person made: the next reconnect counts afresh, and a run under way
    /// leaves no count.
    public func forget() {
        state.withLock {
            $0.carried = nil
            $0.generation += 1
        }
    }

    /// A run's session streamed, with `count`'s tries spent; nothing if forgotten since.
    func reconnected(with count: Count) {
        let now = elapsed()
        state.withLock {
            guard $0.generation == count.generation else { return }
            $0.carried = (count.policy, now)
        }
    }

    /// The count for a new run: the last one's if its session ended within `steadyTime`, else
    /// a new one. Taken once.
    func take() -> Count {
        let now = elapsed()
        return state.withLock {
            defer { $0.carried = nil }
            guard let (policy, at) = $0.carried, now - at < Self.steadyTime else {
                return Count(policy: ReconnectPolicy(), generation: $0.generation)
            }
            return Count(policy: policy, generation: $0.generation)
        }
    }
}
