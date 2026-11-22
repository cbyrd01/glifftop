/// How one try went: a session streams, or it ended before it did.
public enum ReconnectAttempt: Equatable, Sendable {
    case streaming
    case ended(SessionEnd)
}

/// Where a reconnect is, for the window to show.
public enum ReconnectState: Equatable, Sendable {
    /// Waiting `delay` before try `attempt` of `ReconnectPolicy.delays.count`.
    case waiting(attempt: Int, delay: Duration)
    /// Offline: try `attempt` waits for the network, and isn't spent.
    case waitingForNetwork(attempt: Int)
    case trying(attempt: Int)
}

/// How a reconnect ended.
public enum ReconnectResult: Equatable, Sendable {
    case reconnected
    /// The last end: one never tried again, or the last try's.
    case gaveUp(SessionEnd)
    /// The task running `run(after:)` was cancelled (Disconnect).
    case cancelled
}

/// Tries a session again after it ends, as `ReconnectPolicy` says: a countdown before each try,
/// on a clock that stops while the Mac sleeps. `reconnectNow()` cuts it short; while the
/// network is down it stops, and starts again once the network is back. One `run` at a time.
public actor Reconnector {
    /// Each state as it begins; how the reconnect ended is `run(after:)`'s result. Finished
    /// when the reconnector goes.
    public nonisolated let states: AsyncStream<ReconnectState>
    private let statesContinuation: AsyncStream<ReconnectState>.Continuation
    private let clock: any Clock<Duration>
    private let attempt: @Sendable () async -> ReconnectAttempt
    private var online = true
    private var isRunning = false
    /// A `reconnectNow()` for the coming wait: it ends at once.
    private var skipWait = false
    /// The wait in progress, and the sleep that ends it.
    private var waiter: CheckedContinuation<Wake, Never>?
    private var sleeper: Task<Void, Never>?
    /// Counts the waits, so a timer or a cancel only ends its own.
    private var generation = 0

    private enum Wake { case elapsed, now, offline, online, cancelled }

    /// `attempt` starts a session and returns once it streams or ends; it runs in the task
    /// that called `run(after:)`, so a Disconnect cancels it too.
    public init(
        clock: any Clock<Duration> = SuspendingClock(),
        attempt: @escaping @Sendable () async -> ReconnectAttempt
    ) {
        (states, statesContinuation) = AsyncStream.makeStream()
        self.clock = clock
        self.attempt = attempt
    }

    deinit {
        statesContinuation.finish()
    }

    /// Retries after `end` until a session streams, the policy gives up, or the task is
    /// cancelled (Disconnect). An end that may not reconnect gives up at once. A try that
    /// streamed is `.reconnected` even if the cancel came during it: its session is the
    /// caller's to end. A second run while one is under way returns `.cancelled` at once.
    public func run(after end: SessionEnd) async -> ReconnectResult {
        guard !isRunning else { return .cancelled }
        isRunning = true
        defer { isRunning = false }
        var end = end
        // Each run counts its own tries.
        var policy = ReconnectPolicy()
        while let delay = policy.next(after: end) {
            let number = policy.failures
            // A Reconnect Now pressed during the last try doesn't skip this wait.
            skipWait = false
            // A cancel can land after the wait ended and before this resumes.
            if await wait(delay, attempt: number) == .cancelled || Task.isCancelled { return .cancelled }
            statesContinuation.yield(.trying(attempt: number))
            switch await attempt() {
            case .streaming:
                return .reconnected
            case .ended(let ended):
                if Task.isCancelled { return .cancelled }
                end = ended
            }
        }
        return .gaveUp(end)
    }

    /// Ends the current wait now, offline too (the network's state may be wrong: a VPN, say).
    /// Pressed during a try, it does nothing.
    public func reconnectNow() {
        skipWait = true
        wake(.now)
    }

    /// While false, the countdown stops and no try is spent; true starts it again.
    public func networkAvailable(_ on: Bool) {
        guard on != online else { return }
        online = on
        wake(on ? .online : .offline)
    }

    /// The countdown before a try, whole, while online. `.cancelled`, or why it ended.
    private func wait(_ delay: Duration, attempt number: Int) async -> Wake {
        while true {
            if online {
                statesContinuation.yield(.waiting(attempt: number, delay: delay))
                let wake = await sleep(for: delay)
                if wake != .offline { return wake }
            }
            statesContinuation.yield(.waitingForNetwork(attempt: number))
            let wake = await sleep(for: nil)
            if wake != .online { return wake }
        }
    }

    /// Waits until woken, or until `delay` has passed; nil waits for the network. What already
    /// holds (a cancel, a Reconnect Now, the network) ends it at once.
    private func sleep(for delay: Duration?) async -> Wake {
        generation += 1
        let current = generation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let early = early(delay) { return continuation.resume(returning: early) }
                waiter = continuation
                guard let delay else { return }
                sleeper = Task { [clock] in
                    guard (try? await clock.sleep(for: delay)) != nil else { return }
                    self.wake(.elapsed, of: current)
                }
            }
        } onCancel: {
            Task { await self.wake(.cancelled, of: current) }
        }
    }

    /// What ends a wait before it begins.
    private func early(_ delay: Duration?) -> Wake? {
        if Task.isCancelled { return .cancelled }
        if skipWait { return .now }
        if delay == nil, online { return .online }
        if delay != nil, !online { return .offline }
        return nil
    }

    /// Wait `generation`'s timer or cancel; a later wait isn't ended by it.
    private func wake(_ reason: Wake, of generation: Int) {
        if generation == self.generation { wake(reason) }
    }

    private func wake(_ reason: Wake) {
        guard let waiter else { return }
        self.waiter = nil
        sleeper?.cancel()
        sleeper = nil
        waiter.resume(returning: reason)
    }
}
