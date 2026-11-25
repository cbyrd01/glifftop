/// The confined pointer's place on the host, in logical coordinates: the Mac's deltas move it,
/// clamped to the output, and the host's own warps (a focus binding, a window's request) move
/// it too. The host rounds each motion it applies, and its CursorPos reports arrive late, so a
/// report near a position sent in the last second is the echo of that motion, not a warp.
public struct VirtualPointer: Sendable {
    /// How far, on each axis, a report may be from a sent position and still be its echo.
    public static let echoTolerance = 1.5
    /// How long a sent position can still come back as an echo.
    public static let historyAge: Duration = .seconds(1)
    /// The most sent positions kept: a second of a 1 kHz mouse's motion.
    public static let historyLimit = 1024

    public private(set) var x, y: Double
    /// Whether the host shows a pointer (its last report's).
    public private(set) var visible = true
    private var width, height: Double
    /// The positions the host applied for recent motions (`applied`), with when they were sent.
    private var history: [(x: Double, y: Double, at: Duration)] = []
    /// Where the last report put it while hidden: the host's first shown report re-sends it.
    private var hiddenAt: (x: Double, y: Double)?

    /// At (x, y), on an output `width` × `height` logical (the stream's size over its scale).
    /// `sent`: positions sent just before (the absolute motions onto the picture), whose echoes
    /// may still come, as if sent at `time`.
    public init(
        x: Double, y: Double, width: Double, height: Double, sent: [(x: Double, y: Double)] = [],
        at time: Duration = .zero
    ) {
        (self.width, self.height) = (width, height)
        (self.x, self.y) = (Self.clamp(x, width), Self.clamp(y, height))
        history = sent.suffix(Self.historyLimit).map {
            (Self.applied($0.x, extent: width), Self.applied($0.y, extent: height), time)
        }
    }

    /// Where the host puts a motion to `value`: clamped to the output, then rounded to a pixel.
    static func applied(_ value: Double, extent: Double) -> Double {
        clamp(value, extent).rounded()
    }

    /// Moves by a logical delta, clamped to the output, and returns the position to send.
    public mutating func move(dx: Double, dy: Double, at time: Duration) -> (x: Double, y: Double) {
        x = Self.clamp(x + dx, width)
        y = Self.clamp(y + dy, height)
        history.append((Self.applied(x, extent: width), Self.applied(y, extent: height), time))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        return (x, y)
    }

    /// The host's pointer, from a CursorPos at `time`. Hidden: only `visible` changes. Shown:
    /// adopted, unless it is the echo of a recent motion or of where the pointer is, or the
    /// place it was hidden at (upstream's cursor-session Enter re-sends the last position before
    /// the real one). Returns whether it was adopted (the host warped it).
    public mutating func hostReported(x: Double, y: Double, visible: Bool, at time: Duration) -> Bool {
        history.removeAll { time - $0.at > Self.historyAge }
        self.visible = visible
        guard visible else {
            hiddenAt = (x, y)
            return false
        }
        func near(_ sentX: Double, _ sentY: Double) -> Bool {
            abs(sentX - x) <= Self.echoTolerance && abs(sentY - y) <= Self.echoTolerance
        }
        if let hidden = hiddenAt {
            hiddenAt = nil
            if near(hidden.x, hidden.y) { return false }
        }
        let isEcho =
            near(Self.applied(self.x, extent: width), Self.applied(self.y, extent: height))
            || history.contains { near($0.x, $0.y) }
        guard !isEcho else { return false }
        (self.x, self.y) = (Self.clamp(x, width), Self.clamp(y, height))
        return true
    }

    /// A new output size (a virtual screen resized: its coordinates hold): the position clamped
    /// to it. `keepingPlace`, the same output in a new stream size (a mirror fitted anew): the
    /// position and the sent ones scale with it first.
    public mutating func resize(width: Double, height: Double, keepingPlace: Bool = false) {
        if keepingPlace, self.width > 0, self.height > 0 {
            let (sx, sy) = (width / self.width, height / self.height)
            (x, y) = (x * sx, y * sy)
            history = history.map { ($0.x * sx, $0.y * sy, $0.at) }
            hiddenAt = hiddenAt.map { ($0.x * sx, $0.y * sy) }
        }
        (self.width, self.height) = (width, height)
        (x, y) = (Self.clamp(x, width), Self.clamp(y, height))
    }

    private static func clamp(_ value: Double, _ extent: Double) -> Double {
        min(max(value, 0), max(extent - 1, 0))
    }
}
