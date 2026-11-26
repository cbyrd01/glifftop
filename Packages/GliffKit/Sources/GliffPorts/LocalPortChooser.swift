public import GliffTransport

/// Which Mac port a forward takes, the loopback check injected.
///
/// - `choose`: from the remembered port (when in range), else the remote port's own number
///   (8000 for one under 1024), the first free one counting up, at most 100 tries; then
///   `pick()`. A port in `skipping` is never taken.
/// - `exactly`: a port the person typed, tried alone; nil when it is taken or out of range.
/// - Free on 127.0.0.1 alone (a Mac with no ::1) gives `.ipv4Only`.
public struct LocalPortChooser: Sendable {
    public struct Choice: Equatable, Sendable {
        public let port: Int
        public let loopbacks: Loopbacks

        public init(port: Int, loopbacks: Loopbacks) { (self.port, self.loopbacks) = (port, loopbacks) }
    }

    static let tries = 100
    static let lowStart = 8000

    private let check: @Sendable (Int) -> LoopbackPorts.Availability
    private let pick: @Sendable () -> Int?

    public init(
        check: @escaping @Sendable (Int) -> LoopbackPorts.Availability,
        pick: @escaping @Sendable () -> Int?
    ) {
        (self.check, self.pick) = (check, pick)
    }

    /// The system's own check and pick: blocking, so off the main actor.
    public static let system = LocalPortChooser(check: LoopbackPorts.check, pick: LoopbackPorts.pick)

    /// The Mac port a forward of `remote` tries first with nothing remembered: its own number,
    /// or 8000 for one under 1024.
    public static func start(for remote: Int) -> Int {
        PortForward.localPorts.contains(remote) ? remote : lowStart
    }

    public func choose(remote: Int, remembered: Int? = nil, skipping: Set<Int> = []) -> Choice? {
        let ports = PortForward.localPorts
        let start = remembered.flatMap { ports.contains($0) ? $0 : nil } ?? Self.start(for: remote)
        for port in start..<min(start + Self.tries, ports.upperBound + 1) where !skipping.contains(port) {
            if let choice = exactly(port) { return choice }
        }
        return pick().flatMap { skipping.contains($0) ? nil : exactly($0) }
    }

    public func exactly(_ port: Int) -> Choice? {
        guard PortForward.localPorts.contains(port) else { return nil }
        switch check(port) {
        case .free: return Choice(port: port, loopbacks: .both)
        case .freeIPv4Only: return Choice(port: port, loopbacks: .ipv4Only)
        case .taken: return nil
        }
    }
}
