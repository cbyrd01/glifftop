/// One window's side of a handover, as values the app gathers the same way for any window:
/// the key window is the source, the window under the pointer the target.
public struct HandoverFacts: Equatable, Sendable {
    /// The destination while the window is a live mirror of one of its monitors; nil otherwise
    /// (a virtual screen, the machine list, a window not streaming).
    public var group: String?
    /// The window's capture mode is Integrated, not Capture.
    public var integrated: Bool
    /// Its picture shows and its link isn't interrupted or reconnecting.
    public var live: Bool
    /// Shift+Esc released its input.
    public var released: Bool
    /// Its input is captured.
    public var captured: Bool
    /// A sheet is attached to it.
    public var hasSheet: Bool

    public init(
        group: String?, integrated: Bool, live: Bool, released: Bool, captured: Bool, hasSheet: Bool
    ) {
        self.group = group
        self.integrated = integrated
        self.live = live
        self.released = released
        self.captured = captured
        self.hasSheet = hasSheet
    }

    /// A key window a handover can leave: a mirror, its input captured in Integrated, its
    /// picture live, not released. Checked first, it spares the pointer's facts.
    public var canLeave: Bool { group != nil && captured && integrated && live && !released }

    /// A window a handover from `source` can enter: a live Integrated mirror of the same
    /// destination, not released, no sheet.
    func canEnter(from source: HandoverFacts) -> Bool {
        group != nil && group == source.group && integrated && live && !released && !hasSheet
    }
}

/// The app's and the pointer's side of a handover.
public struct HandoverPointer: Equatable, Sendable {
    /// The app is active.
    public var appActive: Bool
    /// A mouse button is held.
    public var buttonHeld: Bool
    /// The pointer is over the target's picture, not its letterbox bars.
    public var overPicture: Bool
    /// The target is the frontmost window at the pointer.
    public var frontmostAtPoint: Bool

    public init(appActive: Bool, buttonHeld: Bool, overPicture: Bool, frontmostAtPoint: Bool) {
        self.appActive = appActive
        self.buttonHeld = buttonHeld
        self.overPicture = overPicture
        self.frontmostAtPoint = frontmostAtPoint
    }

    var allows: Bool { appActive && !buttonHeld && overPicture && frontmostAtPoint }
}

/// When the pointer resting on another mirror of the key window's destination brings that
/// window in front: every condition of `HandoverFacts` and `HandoverPointer` holding for 100 ms
/// from the first qualifying motion over the same target. Times are `Duration`s since an origin
/// the caller picks; it has no clock, and says when it next needs a `tick`. Only a motion starts
/// a count; it answers `handOver` once per entry. A motion over a window covered at the pointer,
/// other than the one counted, changes nothing.
public struct MonitorHandover: Sendable {
    public enum Answer: Equatable, Sendable {
        case nothing
        /// Tick again at this time.
        case waitUntil(Duration)
        /// Bring the target in front now.
        case handOver
    }

    /// How long the pointer rests on the other picture.
    public static let dwell: Duration = .milliseconds(100)

    /// The window the count is for; nil when none is under way.
    public private(set) var target: ObjectIdentifier?
    /// When the count hands over; nil once it has, until the pointer leaves.
    private var deadline: Duration?
    /// The key window, never a target of its own.
    private var key: ObjectIdentifier?

    public init() {}

    /// A motion over the picture of `target`'s window, or over none (an exit).
    public mutating func moved(
        over target: ObjectIdentifier?, source: HandoverFacts, target facts: HandoverFacts?,
        pointer: HandoverPointer, at now: Duration
    ) -> Answer {
        // Another window's picture covered here (mirrors overlap): the motion is the counted
        // window's, which reports it too.
        if let target, target != self.target, !pointer.frontmostAtPoint {
            return deadline.map(Answer.waitUntil) ?? .nothing
        }
        guard let target, target != key, let facts, source.canLeave, facts.canEnter(from: source),
            pointer.allows
        else {
            reset()
            return .nothing
        }
        if target != self.target { (self.target, deadline) = (target, now + Self.dwell) }
        guard let deadline else { return .nothing }
        guard now >= deadline else { return .waitUntil(deadline) }
        self.deadline = nil
        return .handOver
    }

    /// The count's deadline, with the facts as they are now.
    public mutating func tick(
        source: HandoverFacts, target facts: HandoverFacts?, pointer: HandoverPointer, at now: Duration
    ) -> Answer {
        guard let target else { return .nothing }
        return moved(over: target, source: source, target: facts, pointer: pointer, at: now)
    }

    /// An exit or a button going down: the count stops.
    public mutating func reset() {
        (target, deadline) = (nil, nil)
    }

    /// Another window became key (nil: none): the count stops.
    public mutating func keyChanged(to key: ObjectIdentifier?) {
        reset()
        self.key = key
    }
}
