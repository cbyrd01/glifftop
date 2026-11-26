import GliffInput
import Synchronization

/// What the app queues for the session, in the order it happened.
enum Queued: Equatable, Sendable {
    case input(InputMessage)
    /// A clipboard offer or revoke: input after it waits until it is on its way.
    case clipboard(ClipboardCommand)
    /// What follows waits this long from when what came before goes.
    case pause(Duration)
    /// What follows waits until this time on the queue's stopwatch
    /// (`InputQueue.holdWhatFollows(for:)`).
    case until(Duration)
}

/// Input from the app, in order, waiting for the session: `Session.send` appends from any
/// thread at once; the session takes what is queued each time `wakeups` fires. A hold (the
/// `InputBarrier`'s wait, or a pause) keeps what follows it until it ends; what came before it
/// goes as it would.
/// Closed when the session ends:
/// nothing is kept after, and `wakeups` ends.
final class InputQueue: Sendable {
    private struct State {
        /// nil once closed.
        var pending: [Queued]? = []
        /// When the hold ends, on the stopwatch.
        var heldUntil: Duration?
        /// Sleeps until the hold ends, then wakes the drain; one at a time.
        var timer: Task<Void, Never>?
        /// The timers started, for tests.
        var timersStarted = 0
    }

    private let state = Mutex(State())
    /// Fires after an append, and when a hold ends; several may share one wakeup.
    let wakeups: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let clock: any Clock<Duration>
    /// Time on `clock` since the queue was made.
    private let elapsed: @Sendable () -> Duration

    init(clock: any Clock<Duration> = ContinuousClock()) {
        (wakeups, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.clock = clock
        elapsed = clock.stopwatch()
    }

    /// Holds what is appended after this until `duration` from now. What is queued already
    /// goes as it would: another session's barrier wait counted on it (`delay(holding:)`).
    func holdWhatFollows(for duration: Duration) {
        append(.until(elapsed() + duration))
    }

    /// Holds what is left queued until `end`, after any hold before it has ended (`take()`).
    private func hold(until end: Duration, _ state: inout State) {
        state.heldUntil = end
        guard state.timer == nil else { return }
        state.timersStarted += 1
        state.timer = Task { [weak self, clock] in
            while let left = self?.holdLeft() {
                try? await clock.sleep(for: left)
                guard !Task.isCancelled else { return }
            }
        }
    }

    /// How long the hold has left, or nil once it has ended: then the timer has finished, and
    /// the drain is woken.
    private func holdLeft() -> Duration? {
        let now = elapsed()
        let left: Duration? = state.withLock { state in
            guard let end = state.heldUntil, end > now else {
                state.timer = nil
                return nil
            }
            return end - now
        }
        if left == nil { continuation.yield() }
        return left
    }

    /// How long after now what is appended now goes, if it is also held `wait`: once what is
    /// queued before it has gone (the hold now, then each pause and hold queued, in turn) and
    /// that wait is over.
    func delay(holding wait: Duration) -> Duration {
        let now = elapsed()
        return state.withLock { state in
            let queued = (state.pending ?? []).reduce(max((state.heldUntil ?? .zero) - now, .zero)) {
                goes, item in
                switch item {
                case .pause(let duration): goes + duration
                case .until(let end): max(goes, end - now)
                case .input, .clipboard: goes
                }
            }
            return max(queued, wait)
        }
    }

    /// Whether nothing is queued, held or not.
    var isEmpty: Bool { state.withLock { $0.pending?.isEmpty ?? true } }

    /// The timers holds and pauses have started.
    var timersStarted: Int { state.withLock { $0.timersStarted } }

    func append(_ input: InputMessage) {
        append(.input(input))
    }

    func append(_ item: Queued) {
        state.withLock { $0.pending?.append(item) }
        continuation.yield()
    }

    /// Drops what is queued or held.
    func close() {
        state.withLock { state in
            state.pending = nil
            state.timer?.cancel()
        }
        continuation.finish()
    }

    /// Keeps only the queued input `keep` admits, held or not, in its order; clipboard commands,
    /// pauses and holds stay.
    /// `keep` sees each input once, in order, so it may judge each after the ones before it.
    func keepInputs(_ keep: (InputMessage) -> Bool) {
        state.withLock { state in
            guard let pending = state.pending else { return }
            var kept: [Queued] = []
            for item in pending {
                if case .input(let input) = item, !keep(input) { continue }
                kept.append(item)
            }
            state.pending = kept
        }
    }

    /// Everything queued, held or not: a closing session's last input goes before its Bye.
    func takeAll() -> [InputMessage] {
        state.withLock { state in
            guard let taken = state.pending else { return [] }
            state.pending = []
            return taken.compactMap { if case .input(let input) = $0 { input } else { nil } }
        }
    }

    /// The input queued before the first clipboard command, pause or hold not yet over, and that
    /// command; what follows it stays queued, and a pause or hold starts holding it now. Nothing
    /// while held.
    func take() -> (inputs: [InputMessage], command: ClipboardCommand?) {
        let now = elapsed()
        return state.withLock { state in
            let held = state.heldUntil.map { now < $0 } ?? false
            guard !held, let queued = state.pending else { return ([], nil) }
            var inputs: [InputMessage] = []
            for (index, item) in queued.enumerated() {
                let end: Duration
                switch item {
                case .input(let input):
                    inputs.append(input)
                    continue
                case .clipboard(let command):
                    state.pending = Array(queued[(index + 1)...])
                    return (inputs, command)
                case .pause(let duration): end = now + duration
                case .until(let until): end = until
                }
                // A hold already over holds nothing.
                guard end > now else { continue }
                state.pending = Array(queued[(index + 1)...])
                hold(until: end, &state)
                return (inputs, nil)
            }
            state.pending = []
            return (inputs, nil)
        }
    }
}
