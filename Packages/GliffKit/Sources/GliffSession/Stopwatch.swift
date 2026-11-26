extension Clock where Duration == Swift.Duration {
    /// Time on this clock since now: an origin kept as a closure, so a type that stores the
    /// clock as `any Clock<Duration>` can still subtract its instants.
    func stopwatch() -> @Sendable () -> Duration {
        let start = now
        return { start.duration(to: self.now) }
    }
}
