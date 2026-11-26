public import GliffInput

/// The Pings this session has sent and not yet heard answered, each with the modifier releases
/// sent before it, and the releases sent since the last. Upstream answers Pings in order, each Pong echoing its Ping's `t`, but its
/// writer drops a Pong still queued when a newer one is: so a Pong answers its own Ping and
/// every Ping before it, whatever sent them (the stats, a probe). Each Ping's `t` is its own
/// (`SessionCore.pingNow`); were two the same, a Pong counts as the first one's, so a release
/// never goes early.
struct FenceLedger {
    /// A server that never answers can't grow the ledger without bound: past this, the oldest
    /// Ping is forgotten, and what waits for its releases waits out `InputBarrier.limit`.
    static let maxWaiting = 64

    private var waiting: [(t: UInt64, releases: [InputBarrier.Release])] = []
    /// Releases sent since the last Ping: the next one goes behind them.
    private var unpinged: [InputBarrier.Release] = []

    /// `releases` were sent, or dropped by the gate.
    mutating func sent(_ releases: [InputBarrier.Release]) {
        unpinged += releases
        if unpinged.count > Self.maxWaiting { unpinged.removeFirst(unpinged.count - Self.maxWaiting) }
    }

    mutating func pingSent(t: UInt64) {
        waiting.append((t, unpinged))
        unpinged = []
        if waiting.count > Self.maxWaiting { waiting.removeFirst() }
    }

    /// The Pong to Ping `t`: the releases it answers.
    mutating func pongHeard(t: UInt64) -> [InputBarrier.Release] {
        guard let index = waiting.firstIndex(where: { $0.t == t }) else { return [] }
        let answered = waiting[...index].flatMap(\.releases)
        waiting.removeFirst(index + 1)
        return answered
    }

    /// The session has ended, and no Pong is coming: every release not yet answered.
    mutating func ended() -> [InputBarrier.Release] {
        defer { (waiting, unpinged) = ([], []) }
        return waiting.flatMap(\.releases) + unpinged
    }
}

/// The barrier between sessions' input (`InputBarrier`), as a session keeps it.
extension Session {
    /// Queues input for the server, in order, from any thread. A key or button press, motion
    /// and scrolling go only while streaming and not interrupted; a release or a scroll's stop
    /// only if what it ends went (`InputGate`); a keymap always. Nothing is kept once the
    /// session has ended. Until another session's modifier release is answered, what is sent
    /// waits; what was queued before it goes as it would. A modifier release is answered
    /// behind it once it goes (`fence(_:)`).
    public nonisolated func send(_ input: InputMessage) {
        guard let barrier else { return inputs.append(input) }
        let decision = barrier.wait(before: input, from: inputSender, goesAfter: inputs.delay(holding:))
        // After the hold is queued, so an answer already in cannot miss it.
        if let wait = decision.wait, inputs.holdWhatFollows(for: wait.left, awaiting: wait.release) {
            barrier.whenAnswered(wait.release) { [weak inputs] left in
                inputs?.answered(wait.release, left: left)
            }
        }
        inputs.append(input)
        if let release = decision.recorded { inputs.append(.fence(release)) }
    }

    /// `releases` have just been sent (or dropped by the gate): a Ping behind them asks the
    /// server to answer once it has handled them. Without a stream there is no Ping now, and
    /// the next one goes behind them.
    func fence(_ releases: [InputBarrier.Release]) {
        guard !releases.isEmpty else { return }
        fences.sent(releases)
        _ = pingNow()
    }

    /// The Pong to Ping `t`: the releases it answers are answered at the barrier.
    func pongHeard(t: UInt64) {
        answer(fences.pongHeard(t: t))
    }

    /// `releases` are answered at the barrier: what waits for them goes `settle` after.
    func answer(_ releases: [InputBarrier.Release]) {
        for release in releases { barrier?.answered(release) }
    }
}
