import GliffProtocol
import Testing

@testable import GliffInput

/// Mac scrolling to Gliff's axes: positive is down or right (`wl_pointer`), the Mac's deltas
/// already follow its natural-scrolling setting, so the sign flips. Precise deltas are points;
/// a wheel event is its accelerated delta in whole steps (at least one) of 15; a gesture's end
/// stops both axes; momentum is dropped.
@Suite struct ScrollTranslatorTests {
    private func scroll(
        x: Double = 0, y: Double = 0, precise: Bool = true, phase: ScrollPhase = .changed,
        momentum: Bool = false
    ) -> [InputMessage] {
        ScrollTranslator.messages(
            for: ScrollEvent(deltaX: x, deltaY: y, isPrecise: precise, phase: phase, isMomentum: momentum))
    }

    @Test func preciseIsPointsAndSignFlipped() {
        #expect(scroll(y: 12.5) == [.pointerAxis(axis: .vertical, value: -12.5, discrete: nil, stop: false)])
    }

    @Test func bothAxesVerticalFirst() {
        #expect(
            scroll(x: 3, y: -4) == [
                .pointerAxis(axis: .vertical, value: 4, discrete: nil, stop: false),
                .pointerAxis(axis: .horizontal, value: -3, discrete: nil, stop: false),
            ])
    }

    @Test func aWheelStepIsFifteen() {
        #expect(
            scroll(y: 1, precise: false, phase: .none)
                == [.pointerAxis(axis: .vertical, value: -15, discrete: -1, stop: false)])
        #expect(
            scroll(y: -0.1, precise: false, phase: .none)
                == [.pointerAxis(axis: .vertical, value: 15, discrete: 1, stop: false)])
    }

    /// A huge delta (a posted event) is at most 100 steps.
    @Test func aWheelIsAtMostAHundredSteps() {
        #expect(
            scroll(y: -1000, precise: false, phase: .none)
                == [.pointerAxis(axis: .vertical, value: 1500, discrete: 100, stop: false)])
    }

    /// A fast spin keeps the Mac's acceleration: its delta in whole steps.
    @Test func anAcceleratedWheelIsSeveralSteps() {
        #expect(
            scroll(y: 3.7, precise: false, phase: .none)
                == [.pointerAxis(axis: .vertical, value: -60, discrete: -4, stop: false)])
    }

    @Test func aStillAxisSendsNothing() {
        #expect(scroll().isEmpty)
    }

    @Test func aGestureEndStopsBothAxes() {
        let stops: [InputMessage] = [
            .pointerAxis(axis: .vertical, value: 0, discrete: nil, stop: true),
            .pointerAxis(axis: .horizontal, value: 0, discrete: nil, stop: true),
        ]
        #expect(scroll(phase: .ended) == stops)
        #expect(scroll(phase: .cancelled) == stops)
    }

    /// The gesture's last event can still carry distance: it goes before the stops.
    @Test func anEndsDistanceGoesBeforeTheStops() {
        #expect(
            scroll(y: 3, phase: .ended) == [
                .pointerAxis(axis: .vertical, value: -3, discrete: nil, stop: false),
                .pointerAxis(axis: .vertical, value: 0, discrete: nil, stop: true),
                .pointerAxis(axis: .horizontal, value: 0, discrete: nil, stop: true),
            ])
    }

    @Test func aStationaryGestureSendsItsDistance() {
        #expect(scroll(phase: .stationary).isEmpty)
        #expect(
            scroll(y: 1, phase: .stationary) == [
                .pointerAxis(axis: .vertical, value: -1, discrete: nil, stop: false)
            ])
    }

    /// Precise scrolling outside a gesture (a smooth-scrolling mouse driver): its distance as
    /// points, with no stop to follow, as no gesture ends.
    @Test func preciseWithoutAGestureIsPointsWithNoStop() {
        #expect(
            scroll(y: 5, phase: .none) == [
                .pointerAxis(axis: .vertical, value: -5, discrete: nil, stop: false)
            ])
    }

    @Test func momentumIsDropped() {
        #expect(scroll(y: 30, phase: .none, momentum: true).isEmpty)
    }

    @Test func mayBeginIsDropped() {
        #expect(scroll(y: 1, phase: .mayBegin).isEmpty)
    }

    /// A delta that isn't a number never reaches the wire.
    @Test func aNonFiniteDeltaSendsNothing() {
        #expect(scroll(x: .infinity, y: .nan).isEmpty)
    }
}
