import Testing

@testable import GliffInput

/// The pointer handover between two live Integrated mirrors of one destination: resting 100 ms
/// on the other picture hands over, once per entry; any failed condition, an exit, a button or a
/// key change cancels.
@Suite struct MonitorHandoverTests {
    private final class Window {}

    private static func ms(_ value: Int) -> Duration { .milliseconds(value) }

    private let window = Window()
    private let other = Window()
    private var b: ObjectIdentifier { ObjectIdentifier(window) }
    private var c: ObjectIdentifier { ObjectIdentifier(other) }

    /// The key window: a captured, live Integrated mirror of omarchy.
    private static let source = HandoverFacts(
        group: "omarchy", integrated: true, live: true, released: false, captured: true, hasSheet: false)
    /// The other window: a live Integrated mirror of omarchy.
    private static let target = HandoverFacts(
        group: "omarchy", integrated: true, live: true, released: false, captured: false, hasSheet: false)
    /// The app active, no button, the pointer over the target's picture, the target frontmost.
    private static let pointer = HandoverPointer(
        appActive: true, buttonHeld: false, overPicture: true, frontmostAtPoint: true)

    enum FailedCondition: CaseIterable {
        case sourceInCapture, targetInCapture, notCaptured, sourceReleased, targetReleased
        case buttonHeld, anotherGroup, virtualScreen, sourceNotLive, targetNotLive, sheet
        case notFrontmost, overTheBars, appInactive, noTarget

        /// The facts with this one condition failing.
        func facts() -> (source: HandoverFacts, target: HandoverFacts?, pointer: HandoverPointer) {
            var (source, target, pointer) =
                (MonitorHandoverTests.source, MonitorHandoverTests.target, MonitorHandoverTests.pointer)
            switch self {
            case .sourceInCapture: source.integrated = false
            case .targetInCapture: target.integrated = false
            case .notCaptured: source.captured = false
            case .sourceReleased: source.released = true
            case .targetReleased: target.released = true
            case .buttonHeld: pointer.buttonHeld = true
            case .anotherGroup: target.group = "studio"
            case .virtualScreen: (source.group, target.group) = (nil, nil)
            case .sourceNotLive: source.live = false
            case .targetNotLive: target.live = false
            case .sheet: target.hasSheet = true
            case .notFrontmost: pointer.frontmostAtPoint = false
            case .overTheBars: pointer.overPicture = false
            case .appInactive: pointer.appActive = false
            case .noTarget: return (source, nil, pointer)
            }
            return (source, target, pointer)
        }
    }

    /// A rule whose count over `b` started at 0.
    private func entered() -> MonitorHandover {
        var handover = MonitorHandover()
        #expect(
            handover.moved(
                over: b, source: Self.source, target: Self.target, pointer: Self.pointer, at: .zero)
                == .waitUntil(Self.ms(100)))
        return handover
    }

    @Test(arguments: FailedCondition.allCases)
    func eachFailedConditionBlocks(_ condition: FailedCondition) {
        let (source, target, pointer) = condition.facts()
        var handover = MonitorHandover()
        #expect(
            handover.moved(over: b, source: source, target: target, pointer: pointer, at: .zero) == .nothing)
        #expect(
            handover.moved(over: b, source: source, target: target, pointer: pointer, at: Self.ms(150))
                == .nothing)
        #expect(handover.tick(source: source, target: target, pointer: pointer, at: Self.ms(200)) == .nothing)
    }

    /// A condition failing during the dwell cancels it, though the pointer stays.
    @Test(arguments: FailedCondition.allCases)
    func aConditionFailingDuringTheDwellCancels(_ condition: FailedCondition) {
        let (source, target, pointer) = condition.facts()
        var handover = entered()
        #expect(handover.tick(source: source, target: target, pointer: pointer, at: Self.ms(100)) == .nothing)
        #expect(
            handover.tick(source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(150))
                == .nothing)
    }

    @Test func firesAt100msWithNoFurtherMotion() {
        var handover = entered()
        #expect(
            handover.tick(source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(99))
                == .waitUntil(Self.ms(100)))
        #expect(
            handover.tick(source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(100))
                == .handOver)
    }

    @Test func aMotionAfterTheDwellHandsOver() {
        var handover = entered()
        #expect(
            handover.moved(
                over: b, source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(40))
                == .waitUntil(Self.ms(100)))
        #expect(
            handover.moved(
                over: b, source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(120))
                == .handOver)
    }

    @Test func leavingAt99msCancels() {
        var handover = entered()
        #expect(
            handover.moved(
                over: nil, source: Self.source, target: nil, pointer: Self.pointer, at: Self.ms(99))
                == .nothing)
        #expect(
            handover.tick(source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(100))
                == .nothing)
    }

    @Test func aButtonCancels() {
        var handover = entered()
        handover.reset()
        #expect(
            handover.tick(source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(100))
                == .nothing)
        // The next motion starts a new count.
        #expect(
            handover.moved(
                over: b, source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(110))
                == .waitUntil(Self.ms(210)))
    }

    @Test func aKeyChangeCancels() {
        var handover = entered()
        handover.reset()
        #expect(handover.target == nil)
        #expect(
            handover.tick(source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(150))
                == .nothing)
    }

    @Test func aNewTargetRestartsTheCount() {
        var handover = entered()
        #expect(
            handover.moved(
                over: c, source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(80))
                == .waitUntil(Self.ms(180)))
        #expect(handover.target == c)
        #expect(
            handover.tick(source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(100))
                == .waitUntil(Self.ms(180)))
        #expect(
            handover.tick(source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(180))
                == .handOver)
    }

    @Test func itAnswersOncePerEntry() {
        var handover = entered()
        #expect(
            handover.tick(source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(100))
                == .handOver)
        #expect(
            handover.tick(source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(110))
                == .nothing)
        #expect(
            handover.moved(
                over: b, source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(300))
                == .nothing)
        // Out and back in: a new entry.
        _ = handover.moved(
            over: nil, source: Self.source, target: nil, pointer: Self.pointer, at: Self.ms(310))
        #expect(
            handover.moved(
                over: b, source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(320))
                == .waitUntil(Self.ms(420)))
    }

    /// The key window's own picture under the pointer is no other window.
    @Test func theKeyWindowIsNeverItsOwnTarget() {
        var handover = MonitorHandover()
        handover.keyChanged(to: b)
        #expect(
            handover.moved(
                over: b, source: Self.source, target: Self.target, pointer: Self.pointer, at: .zero)
                == .nothing)
        #expect(
            handover.moved(
                over: c, source: Self.source, target: Self.target, pointer: Self.pointer, at: .zero)
                == .waitUntil(Self.ms(100)))
    }

    /// A key change stops the count as a reset does.
    @Test func aNewKeyWindowCancels() {
        var handover = entered()
        handover.keyChanged(to: c)
        #expect(handover.target == nil)
        #expect(
            handover.tick(source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(150))
                == .nothing)
    }

    /// A tick with no count under way (only a motion starts one) answers nothing.
    @Test func aTickAloneStartsNothing() {
        var handover = MonitorHandover()
        #expect(
            handover.tick(source: Self.source, target: Self.target, pointer: Self.pointer, at: Self.ms(500))
                == .nothing)
    }
}
