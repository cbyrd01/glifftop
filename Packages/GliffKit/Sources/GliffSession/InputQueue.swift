import GliffInput
import Synchronization
import os

/// What the app queues for the session, in the order it happened.
enum Queued: Equatable, Sendable {
    case input(InputMessage)
    /// A clipboard offer or revoke: input after it waits until it is on its way.
    case clipboard(ClipboardCommand)
    /// What follows waits this long from when what came before goes.
    case pause(Duration)
    /// What follows waits until this time on the queue's stopwatch, or less once the release it
    /// waits for is answered (`InputQueue.holdWhatFollows(for:awaiting:)`).
    case until(Duration, awaiting: InputBarrier.Release?)
    /// This session's modifier release, queued before it: once it has gone, the session asks its
    /// server to answer behind it.
    case fence(InputBarrier.Release)
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
        /// The release the hold waits for, until it is answered.
        var awaiting: InputBarrier.Release?
        /// Sleeps until the hold ends, then wakes the drain; one at a time.
        var timer: Task<Void, Never>?
        /// Which timer is current: one an answer replaced does nothing more.
        var timerNumber = 0
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

    /// Holds what is appended after this until `duration` from now, or until `left` after
    /// `release` is answered (`answered(_:left:)`), if sooner. What is queued already goes as
    /// it would: another session's barrier wait counted on it (`delay(holding:)`). A hold for
    /// `release` already queued or reached holds what follows already: false, and nothing new.
    @discardableResult
    func holdWhatFollows(for duration: Duration, awaiting release: InputBarrier.Release? = nil) -> Bool {
        let added = state.withLock { state in
            guard let pending = state.pending else { return false }
            if let release {
                let queued = pending.contains { if case .until(_, release?) = $0 { true } else { false } }
                guard state.awaiting != release, !queued else { return false }
            }
            state.pending = pending + [.until(elapsed() + duration, awaiting: release)]
            return true
        }
        if added { continuation.yield() }
        return added
    }

    /// `release` was answered: holds waiting for it end `left` from now, if that is sooner.
    func answered(_ release: InputBarrier.Release, left: Duration) {
        let end = elapsed() + left
        state.withLock { state in
            state.pending = state.pending?.map { item in
                guard case .until(let until, let awaited?) = item, awaited == release else { return item }
                return .until(min(until, end), awaiting: nil)
            }
            guard state.awaiting == release, let held = state.heldUntil else { return }
            state.awaiting = nil
            // The timer sleeps until the old end: a new one wakes at the new end.
            state.timer?.cancel()
            state.timer = nil
            hold(until: min(held, end), awaiting: nil, &state)
        }
    }

    /// Holds what is left queued until `end`, after any hold before it has ended (`take()`).
    private func hold(until end: Duration, awaiting release: InputBarrier.Release?, _ state: inout State) {
        state.heldUntil = end
        state.awaiting = release
        guard state.timer == nil else { return }
        state.timersStarted += 1
        state.timerNumber += 1
        let number = state.timerNumber
        state.timer = Task { [weak self, clock] in
            while let left = self?.holdLeft(timer: number) {
                try? await clock.sleep(for: left)
                guard !Task.isCancelled else { return }
            }
        }
    }

    /// How long the hold has left, or nil once it has ended: then the timer has finished, and
    /// the drain is woken. Nil for a timer no longer current.
    private func holdLeft(timer: Int) -> Duration? {
        let now = elapsed()
        enum Hold {
            case left(Duration)
            case ended(unanswered: Bool)
            case replaced
        }
        let hold: Hold = state.withLock { state in
            guard state.timerNumber == timer else { return .replaced }
            guard let end = state.heldUntil, end > now else {
                let unanswered = state.awaiting != nil
                (state.timer, state.awaiting) = (nil, nil)
                return .ended(unanswered: unanswered)
            }
            return .left(end - now)
        }
        switch hold {
        case .left(let left): return left
        case .replaced: return nil
        case .ended(let unanswered):
            if unanswered {
                Self.log.notice("input held until the limit: another tab's modifier release went unanswered")
            }
            continuation.yield()
            return nil
        }
    }

    private static let log = Logger(subsystem: "io.github.cbyrd01.Glifftop", category: "GliffSession")

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
                case .until(let end, _): max(goes, end - now)
                case .input, .clipboard, .fence: goes
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

    /// Drops what is queued or held: the releases among it, which never go.
    @discardableResult
    func close() -> [InputBarrier.Release] {
        let dropped = state.withLock { state in
            defer {
                state.pending = nil
                state.timer?.cancel()
            }
            return Self.fences(in: state.pending ?? [])
        }
        continuation.finish()
        return dropped
    }

    /// Keeps only the queued input `keep` admits, held or not, in its order; clipboard commands,
    /// pauses, holds and fences stay.
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

    /// Everything queued, held or not, and its fences: a closing session's last input goes
    /// before its Bye. Clipboard commands are dropped.
    func takeAll() -> Taken {
        state.withLock { state in
            guard let queued = state.pending else { return Taken() }
            state.pending = []
            let inputs = queued.compactMap { if case .input(let input) = $0 { input } else { nil } }
            return Taken(inputs: inputs, fences: Self.fences(in: queued))
        }
    }

    private static func fences(in queued: [Queued]) -> [InputBarrier.Release] {
        queued.compactMap { if case .fence(let release) = $0 { release } else { nil } }
    }

    /// What `take()` lets go: the input, the clipboard command that follows it, and the fences
    /// among the input (this session's releases, to be answered behind it).
    struct Taken: Equatable {
        var inputs: [InputMessage] = []
        var command: ClipboardCommand?
        var fences: [InputBarrier.Release] = []
    }

    /// The input queued before the first clipboard command, pause or hold not yet over, and that
    /// command; what follows it stays queued, and a pause or hold starts holding it now. Nothing
    /// while held.
    func take() -> Taken {
        let now = elapsed()
        return state.withLock { state in
            let held = state.heldUntil.map { now < $0 } ?? false
            guard !held, let queued = state.pending else { return Taken() }
            var taken = Taken()
            for (index, item) in queued.enumerated() {
                let end: Duration
                var awaiting: InputBarrier.Release?
                switch item {
                case .input(let input):
                    taken.inputs.append(input)
                    continue
                case .fence(let release):
                    taken.fences.append(release)
                    continue
                case .clipboard(let command):
                    state.pending = Array(queued[(index + 1)...])
                    taken.command = command
                    return taken
                case .pause(let duration): end = now + duration
                case .until(let until, let release): (end, awaiting) = (until, release)
                }
                // A hold already over holds nothing.
                guard end > now else { continue }
                state.pending = Array(queued[(index + 1)...])
                hold(until: end, awaiting: awaiting, &state)
                return taken
            }
            state.pending = []
            return taken
        }
    }
}
