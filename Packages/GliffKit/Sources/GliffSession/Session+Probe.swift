/// The probe after a wake or a network change. A link that died while the Mac slept looks
/// healthy until ssh's keepalive gives up, about a minute later: `Liveness` runs on a clock
/// that stops during sleep. The probe asks at once instead.
extension Session {
    /// While streaming, sends a Ping now; unless its Pong (or bytes `Liveness.probeGrace` after
    /// it) arrives within `Liveness.probeLimit`, the link counts as lost and the session ends
    /// as `.connectionLost`. A later probe replaces it. From any thread, in no guaranteed
    /// order; before streaming (the handshake) it does nothing.
    public nonisolated func probe() {
        Task { await self.startProbe() }
    }

    private func startProbe() async {
        let now = Self.now()
        guard let ping = core.pingNow(now: now) else { return }
        liveness.probe(ping: now, at: Self.uptime())
        await perform([ping])
    }

    /// Ends the session when a probe went unanswered (each tick).
    func checkProbe() async {
        guard !core.isFinished, liveness.probeFailed(at: Self.uptime()) else { return }
        await perform(core.finish(.connectionLost))
    }
}
