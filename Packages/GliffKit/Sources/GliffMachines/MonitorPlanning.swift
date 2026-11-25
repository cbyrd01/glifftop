public import GliffTransport

/// The monitors other windows show for one destination: by live sessions (a named mirror's
/// name, a Focused Monitor mirror's output once the server names it), and by ended windows of
/// a named monitor, which start again in place rather than in a new window.
public struct ShownMonitors: Equatable, Sendable {
    public var live: Set<String>
    public var ended: Set<String>

    public init(live: Set<String> = [], ended: Set<String> = []) {
        (self.live, self.ended) = (live, ended)
    }
}

/// What Show All Monitors does with a host's listed monitors.
public enum MonitorPlan: Equatable, Sendable {
    /// The host listed no monitor to show.
    case empty
    /// Every listed monitor is shown already.
    case allShown
    /// The monitors to open, in host order.
    case open([MonitorOpening])
}

/// One monitor to show: its options are the source window's with the screen `.named(name)`;
/// `inPlace` when an ended window of it starts again instead of a new window opening.
public struct MonitorOpening: Equatable, Sendable {
    public var name: String
    public var options: MachineOptions
    public var inPlace: Bool

    public init(name: String, options: MachineOptions, inPlace: Bool) {
        (self.name, self.options, self.inPlace) = (name, options, inPlace)
    }
}

/// The rules for showing every monitor of a host at once.
public enum MonitorPlanning {
    /// Left to right, then top to bottom, then by name; a monitor without a position after
    /// those with one, by name.
    public static func hostOrder(_ screens: [RemoteScreen]) -> [RemoteScreen] {
        screens.sorted { sortKey($0) < sortKey($1) }
    }

    /// Each listed monitor not shown, in host order, by name (the focused one too, so each
    /// window means one monitor for its life), with the source window's options.
    public static func plan(listed: [RemoteScreen], shown: ShownMonitors, source: MachineOptions)
        -> MonitorPlan
    {
        guard !listed.isEmpty else { return .empty }
        let openings = hostOrder(listed).filter { !shown.live.contains($0.name) }.map { screen in
            var options = source
            options.screen = .named(screen.name)
            return MonitorOpening(
                name: screen.name, options: options, inPlace: shown.ended.contains(screen.name))
        }
        return openings.isEmpty ? .allShown : .open(openings)
    }

    /// The monitor a window mirrors: a named mirror's from its start, a Focused Monitor
    /// mirror's once the server names its output (a name a monitor's could be); a virtual
    /// screen's none.
    public static func monitor(shownBy screen: ScreenChoice, output: String?) -> String? {
        switch screen {
        case .named(let name): name
        case .focused: output.flatMap { ScreenListParser.isMonitorName($0) ? $0 : nil }
        case .virtual: nil
        }
    }

    /// Positioned monitors first, by x then y; then by name.
    private static func sortKey(_ screen: RemoteScreen) -> (Int, Int, Int, String) {
        guard let x = screen.x, let y = screen.y else { return (1, 0, 0, screen.name) }
        return (0, x, y, screen.name)
    }
}
