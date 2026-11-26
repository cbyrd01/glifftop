/// One of the Mac's displays, as placement orders it: its number (`NSScreenNumber`) and its
/// frame's left and top edges, in AppKit's coordinates (y grows upward).
public struct DisplayRect: Equatable, Sendable {
    public var id: UInt32
    public var minX, maxY: Double

    public init(id: UInt32, minX: Double, maxY: Double) {
        (self.id, self.minX, self.maxY) = (id, minX, maxY)
    }
}

/// A window to place, by what it shows: one the command opens, one already showing a monitor
/// (it keeps its place), or the key window (`monitor` nil for a virtual screen; `movable`
/// false when it is in a shared tab group or in full screen).
public enum PlacedWindow: Equatable, Sendable {
    case new(monitor: String)
    case stays(monitor: String)
    case key(monitor: String?, movable: Bool)
}

/// A monitor's window on a display: the cascade `step` from the display's visible top-left,
/// whether it `moves` there, and whether it `fits` the display afterwards (a moved key window).
public struct Slot: Equatable, Sendable {
    public var display: UInt32
    public var step: Int
    public var moves: Bool
    public var fits: Bool

    public init(display: UInt32, step: Int, moves: Bool, fits: Bool) {
        (self.display, self.step, self.moves, self.fits) = (display, step, moves, fits)
    }
}

/// Places a host's monitor windows on the Mac's displays in the host's order, ordering only:
/// the first monitor on the leftmost display, and so on; monitors past the last display
/// cascade on the last. Sizes and gaps aren't mirrored.
public enum MonitorPlacement {
    /// Left to right; of displays with the same left edge, the higher first.
    public static func displayOrder(_ displays: [DisplayRect]) -> [DisplayRect] {
        displays.sorted { ($0.minX, -$0.maxY) < ($1.minX, -$1.maxY) }
    }

    /// Every monitor of `hostOrder` with a window among `windows` gets a slot, keyed by its
    /// name; each window on a display counts a step, those that stay included. Only new
    /// windows and a movable key window move; a virtual-screen key window takes no slot.
    public static func slots(hostOrder: [String], windows: [PlacedWindow], displays: [DisplayRect])
        -> [String: Slot]
    {
        let ordered = displayOrder(displays)
        guard let last = ordered.indices.last else { return [:] }
        // A monitor shown twice takes the key window's place, else the last window's.
        var kinds: [String: (moves: Bool, fits: Bool)] = [:]
        var key: (monitor: String, movable: Bool)?
        for window in windows {
            switch window {
            case .new(let monitor): kinds[monitor] = (true, false)
            case .stays(let monitor): kinds[monitor] = (false, false)
            case .key(let monitor?, let movable): key = (monitor, movable)
            case .key(nil, _): break
            }
        }
        if let key { kinds[key.monitor] = (key.movable, key.movable) }
        var slots: [String: Slot] = [:]
        var steps = [Int](repeating: 0, count: ordered.count)
        for (index, monitor) in hostOrder.enumerated() {
            guard let kind = kinds[monitor] else { continue }
            let display = min(index, last)
            slots[monitor] = Slot(
                display: ordered[display].id, step: steps[display], moves: kind.moves, fits: kind.fits)
            steps[display] += 1
        }
        return slots
    }
}
