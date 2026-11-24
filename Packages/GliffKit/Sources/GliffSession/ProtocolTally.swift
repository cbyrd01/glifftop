/// The inspector's table: per direction and type, how many frames, how many bytes, when the
/// last came and how many in the last second; and the latest events, newest last.
public struct ProtocolTally: Sendable {
    public struct Row: Equatable, Sendable {
        public var direction: ProtocolEvent.Direction
        public var type: String
        public var count: Int
        public var bytes: Int
        public var last: ContinuousClock.Instant
        public var perSecond: Int
    }

    public static let recentLimit = 200

    private struct Key: Hashable {
        let direction: ProtocolEvent.Direction
        let type: String
    }

    private struct Totals {
        var count = 0
        var bytes = 0
        var last: ContinuousClock.Instant
        /// The times of the last second's frames, oldest first.
        var lastSecond: [ContinuousClock.Instant] = []
    }

    private var totals: [Key: Totals] = [:]
    /// In the order observed: a sent frame is told once written, so a quick reply can come
    /// before it.
    public private(set) var recent: [ProtocolEvent] = []

    public init() {}

    public mutating func add(_ event: ProtocolEvent) {
        let key = Key(direction: event.direction, type: event.type)
        var totals = self.totals[key] ?? Totals(last: event.time)
        totals.count += 1
        totals.bytes += event.bytes
        totals.last = event.time
        totals.lastSecond.removeAll { event.time - $0 >= .seconds(1) }
        totals.lastSecond.append(event.time)
        self.totals[key] = totals
        recent.append(event)
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }

    /// Sorted by direction (sent first), then type.
    public func rows(now: ContinuousClock.Instant) -> [Row] {
        totals.map { key, totals in
            Row(
                direction: key.direction, type: key.type, count: totals.count, bytes: totals.bytes,
                last: totals.last, perSecond: totals.lastSecond.count { now - $0 < .seconds(1) })
        }
        .sorted { ($0.direction, $0.type) < ($1.direction, $1.type) }
    }

    public mutating func clear() {
        totals = [:]
        recent = []
    }
}
