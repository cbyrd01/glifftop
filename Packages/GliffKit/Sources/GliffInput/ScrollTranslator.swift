import GliffProtocol

/// Where a scroll is in its gesture (`NSEvent.Phase`); a wheel's events have none.
public enum ScrollPhase: Sendable {
    case none, mayBegin, began, stationary, changed, ended, cancelled
}

/// A Mac scroll event as values: its deltas (already following the natural-scrolling setting),
/// whether they are precise points (a trackpad or Magic Mouse) or wheel lines, its gesture
/// phase, and whether it is momentum after the fingers lifted.
public struct ScrollEvent: Sendable, Equatable {
    public var deltaX, deltaY: Double
    public var isPrecise: Bool
    public var phase: ScrollPhase
    public var isMomentum: Bool

    public init(deltaX: Double, deltaY: Double, isPrecise: Bool, phase: ScrollPhase, isMomentum: Bool) {
        (self.deltaX, self.deltaY, self.isPrecise) = (deltaX, deltaY, isPrecise)
        (self.phase, self.isMomentum) = (phase, isMomentum)
    }
}

/// Mac scrolling to Gliff's axes, after upstream's `scroll_delta`. Gliff's positive is down or
/// right (`wl_pointer`), the Mac's the other way, so the sign flips. Precise deltas go as
/// points (a precise event outside a gesture too, with no stop: no gesture ends). A wheel
/// event is its accelerated delta in whole steps, at least one and at most 100, each 15, with
/// the step count as `discrete` (the remote's `axis_discrete`), so a fast spin keeps the Mac's
/// acceleration. A gesture's end sends any distance it carries, then stops both axes. Momentum
/// is dropped (the remote's own kinetic scrolling follows the stop), and so is a gesture that
/// may begin.
public enum ScrollTranslator {
    private static let notch = 15.0
    private static let maxSteps = 100.0

    public static func messages(for event: ScrollEvent) -> [InputMessage] {
        if event.isMomentum || event.phase == .mayBegin { return [] }
        let distance = [(Axis.vertical, event.deltaY), (.horizontal, event.deltaX)].compactMap {
            axis, delta -> InputMessage? in
            guard delta != 0, delta.isFinite else { return nil }
            guard !event.isPrecise else {
                return .pointerAxis(axis: axis, value: -delta, discrete: nil, stop: false)
            }
            let steps = min(max(delta.magnitude.rounded(), 1), maxSteps)
            let step = Int32(delta > 0 ? -steps : steps)
            return .pointerAxis(axis: axis, value: notch * Double(step), discrete: step, stop: false)
        }
        guard event.phase == .ended || event.phase == .cancelled else { return distance }
        return distance
            + [Axis.vertical, .horizontal].map { .pointerAxis(axis: $0, value: 0, discrete: nil, stop: true) }
    }
}
