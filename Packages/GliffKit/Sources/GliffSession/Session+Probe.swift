import Synchronization

/// The probe after a wake or a network change. A link that died while the Mac slept looks
/// healthy until ssh's keepalive gives up, about a minute later: `Liveness` runs on a clock
/// that stops during sleep. The probe asks at once instead.
extension Session {
    /// While streaming, sends a Ping now; unless its Pong (or bytes `Liveness.probeGrace` after
    /// it) arrives within `Liveness.probeLimit`, the link counts as lost and the session ends
    /// as `.connectionLost`. A later probe or withdrawal replaces it, in the order called.
    /// From any thread; before streaming (the handshake) it does nothing.
    public nonisolated func probe() {
        let order = nextProbeCall()
        Task { await self.startProbe(order: order) }
    }

    /// The network went away: a probe waiting is dropped, as it couldn't be answered; the
    /// probe sent once the network is back decides. From any thread.
    public nonisolated func withdrawProbe() {
        let order = nextProbeCall()
        Task { await self.dropProbe(order: order) }
    }

    private nonisolated func nextProbeCall() -> UInt64 {
        probeCalls.withLock {
            $0 += 1
            return $0
        }
    }

    private func dropProbe(order: UInt64) {
        liveness.withdrawProbe(order: order)
    }

    private func startProbe(order: UInt64) async {
        let now = Self.now()
        guard let ping = core.pingNow(now: now) else { return }
        liveness.probe(ping: now, at: Self.uptime(), order: order)
        await perform([ping])
    }

    /// Ends the session when a probe went unanswered (each tick).
    func checkProbe() async {
        guard !core.isFinished, liveness.probeFailed(at: Self.uptime()) else { return }
        await perform(core.finish(.connectionLost))
    }
}
