/// Where a handover's pointer entered the other window's picture (remote, logical): the target
/// of that window's next activation, in place of the Mac pointer, for 500 ms and used once.
public struct HandoverEntry: Sendable {
    /// How long the entry point waits for the activation it is for.
    public static let lifetime: Duration = .milliseconds(500)

    private var point: (x: Double, y: Double, at: ContinuousClock.Instant)?

    public init() {}

    /// A handover brings the window in front with the pointer at (`x`, `y`).
    public mutating func set(x: Double, y: Double, at now: ContinuousClock.Instant) {
        point = (x, y, now)
    }

    /// The entry point, if one was set less than 500 ms before `now`; it goes either way.
    public mutating func take(at now: ContinuousClock.Instant) -> (x: Double, y: Double)? {
        defer { point = nil }
        guard let point, now - point.at < Self.lifetime else { return nil }
        return (point.x, point.y)
    }

    public mutating func clear() { point = nil }
}
