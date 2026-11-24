import GliffProtocol
import Testing

@testable import GliffSession

/// When the window's size and scale go to the server as a Resize (upstream
/// `request_resize`, plus a settle delay).
@Suite struct ResizeRulesTests {
    private typealias View = ResizeRules.View

    private static func target(
        _ width: UInt32, _ height: UInt32, backing: Double = 2, factor: Double = 1,
        resolution: VirtualResolution = .retina
    ) -> ViewTarget {
        ViewTarget(
            width: width, height: height, backingScale: backing, textFactor: factor, resolution: resolution)
    }

    private static let mirrorView = View(width: 2560, height: 1440, scale: 1)
    private static let virtualView = View(width: 1920, height: 1080, scale: 1)

    /// The session's first size goes at once: the server's screen starts at its own default.
    @Test func theFirstTargetGoesAtOnce() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000), now: 0)
        #expect(
            rules.due(now: 0, headless: true, view: Self.virtualView, pipeline: nil)
                == .resize(width: 1600, height: 1000, scale: 2))
    }

    @Test func aLaterTargetWaitsForTheSettle() {
        var rules = Self.sentFirst()
        rules.set(Self.target(1400, 900), now: 1000)
        #expect(rules.due(now: 1199, headless: true, view: Self.virtualView, pipeline: nil) == nil)
        #expect(
            rules.due(now: 1200, headless: true, view: Self.virtualView, pipeline: nil)
                == .resize(width: 1400, height: 900, scale: 2))
    }

    @Test func nothingGoesDuringALiveResize() {
        var rules = ResizeRules()
        rules.setLiveResize(true)
        rules.set(Self.target(1600, 1000), now: 0)
        #expect(rules.due(now: 5000, headless: true, view: Self.virtualView, pipeline: nil) == nil)
    }

    /// A drag's end sends its last size at once, with no settle.
    @Test func theEndOfALiveResizeSendsAtOnce() {
        var rules = Self.sentFirst()
        rules.setLiveResize(true)
        for step in 0...25 {
            rules.set(
                Self.target(1000 + UInt32(step) * 16, 600 + UInt32(step) * 12), now: 1000 + UInt64(step) * 16)
            #expect(
                rules.due(
                    now: 1000 + UInt64(step) * 16 + 300, headless: true, view: Self.virtualView, pipeline: nil
                ) == nil)
        }
        rules.setLiveResize(false)
        #expect(
            rules.due(now: 1401, headless: true, view: Self.virtualView, pipeline: nil)
                == .resize(width: 1400, height: 900, scale: 2))
    }

    @Test func aTargetEqualToTheViewIsSatisfied() {
        var rules = ResizeRules()
        #expect(!rules.isSatisfied(headless: true, view: Self.virtualView, pipeline: nil))
        rules.set(Self.target(1920, 1080, backing: 1), now: 0)
        #expect(rules.isSatisfied(headless: true, view: Self.virtualView, pipeline: nil))
        rules.set(Self.target(1600, 1000), now: 0)
        #expect(!rules.isSatisfied(headless: true, view: Self.virtualView, pipeline: nil))
    }

    /// Only the size a drag ended on skips the settle: a later change (a snap) waits.
    @Test func aChangeAfterADragEndsWaitsForTheSettle() {
        var rules = Self.sentFirst()
        rules.setLiveResize(true)
        rules.set(Self.target(1200, 800), now: 1000)
        rules.setLiveResize(false)
        rules.set(Self.target(1300, 850), now: 1010)
        #expect(rules.due(now: 1011, headless: true, view: Self.virtualView, pipeline: nil) == nil)
        #expect(
            rules.due(now: 1210, headless: true, view: Self.virtualView, pipeline: nil)
                == .resize(width: 1300, height: 850, scale: 2))
    }

    /// A target too small to send leaves nothing to wait for.
    @Test func aTargetTooSmallToSendIsSatisfied() {
        var rules = ResizeRules()
        rules.set(Self.target(300, 200), now: 0)
        #expect(rules.isSatisfied(headless: true, view: Self.virtualView, pipeline: nil))
    }

    /// Rules whose first target (1600×1000 at 2) has gone, at 0.
    private static func sentFirst() -> ResizeRules {
        var rules = ResizeRules()
        rules.set(target(1600, 1000), now: 0)
        _ = rules.due(now: 0, headless: true, view: virtualView, pipeline: nil)
        return rules
    }

    /// A scale that isn't a number would never equal what was sent: it would go every tick.
    @Test(arguments: [(Double.nan, 1.0), (2, .nan), (.infinity, 1), (2, -.infinity)])
    func aScaleThatIsNotANumberIsNeverSent(backing: Double, factor: Double) {
        for headless in [true, false] {
            var rules = ResizeRules()
            rules.set(Self.target(1600, 1000, backing: backing, factor: factor), now: 0)
            #expect(rules.due(now: 500, headless: headless, view: Self.virtualView, pipeline: nil) == nil)
        }
    }

    /// A drag the window doesn't report as a live resize sends once, when it pauses.
    @Test func aDragSendsOnceItSettles() {
        var rules = Self.sentFirst()
        var sent: [ClientMessage] = []
        var now: UInt64 = 1000
        for step in 0...25 {
            rules.set(Self.target(1000 + UInt32(step) * 16, 600 + UInt32(step) * 12), now: now)
            if let message = rules.due(now: now, headless: true, view: Self.virtualView, pipeline: nil) {
                sent.append(message)
            }
            now += 16
        }
        let last = now - 16
        #expect(rules.due(now: last + 199, headless: true, view: Self.virtualView, pipeline: nil) == nil)
        if let message = rules.due(now: last + 200, headless: true, view: Self.virtualView, pipeline: nil) {
            sent.append(message)
        }
        #expect(rules.due(now: last + 900, headless: true, view: Self.virtualView, pipeline: nil) == nil)
        #expect(sent == [.resize(width: 1400, height: 900, scale: 2)])
    }

    @Test func theSameRequestIsNotSentTwice() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000), now: 0)
        #expect(rules.due(now: 200, headless: true, view: Self.virtualView, pipeline: nil) != nil)
        rules.set(Self.target(1600, 1000), now: 300)
        #expect(rules.due(now: 600, headless: true, view: Self.virtualView, pipeline: nil) == nil)
    }

    @Test func theServersViewIsNotRequested() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000), now: 0)
        #expect(
            rules.due(
                now: 200, headless: true, view: View(width: 1600, height: 1000, scale: 2), pipeline: nil)
                == nil)
        // A mirror ignores the scale: its view alone decides.
        #expect(
            rules.due(
                now: 200, headless: false, view: View(width: 1600, height: 1000, scale: 1), pipeline: nil)
                == nil)
    }

    /// The server rounds a virtual screen's mode (`clean_mode`); its answer
    /// sends nothing more.
    @Test func aRoundedViewDoesNotSendAgain() {
        var rules = ResizeRules()
        rules.set(Self.target(1366, 768, backing: 1.25), now: 0)
        #expect(
            rules.due(now: 200, headless: true, view: Self.virtualView, pipeline: nil)
                == .resize(width: 1366, height: 768, scale: 1.25))
        #expect(
            rules.due(
                now: 900, headless: true, view: View(width: 1360, height: 760, scale: 1.25), pipeline: nil)
                == nil)
    }

    @Test(arguments: [(319, 600), (800, 239), (0, 0)] as [(UInt32, UInt32)])
    func tooSmallIsNotSent(width: UInt32, height: UInt32) {
        var rules = ResizeRules()
        rules.set(Self.target(width, height), now: 0)
        #expect(rules.due(now: 200, headless: true, view: Self.virtualView, pipeline: nil) == nil)
    }

    @Test func aVirtualScreenGetsTheTextFactor() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000, factor: 0.75), now: 0)
        #expect(
            rules.due(now: 200, headless: true, view: Self.virtualView, pipeline: nil)
                == .resize(width: 1600, height: 1000, scale: 1.5))
    }

    @Test func aMirrorGetsTheBackingScale() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000, factor: 0.75), now: 0)
        #expect(
            rules.due(now: 200, headless: false, view: Self.mirrorView, pipeline: nil)
                == .resize(width: 1600, height: 1000, scale: 2))
    }

    /// A 1× display, smaller text: the remote scale stays 1.
    @Test func aOneTimesDisplayNeverGoesBelowScaleOne() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000, backing: 1, factor: 0.5), now: 0)
        #expect(
            rules.due(now: 200, headless: true, view: Self.virtualView, pipeline: nil)
                == .resize(width: 1600, height: 1000, scale: 1))
    }

    @Test func aTextFactorChangeSendsTheSameSizeAtTheNewScale() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000), now: 0)
        _ = rules.due(now: 200, headless: true, view: Self.virtualView, pipeline: nil)
        rules.set(Self.target(1600, 1000, factor: 0.875), now: 300)
        #expect(
            rules.due(
                now: 500, headless: true, view: View(width: 1600, height: 1000, scale: 2), pipeline: nil)
                == .resize(width: 1600, height: 1000, scale: 1.75))
    }

    /// The window moves to a display of another backing scale.
    @Test func aBackingScaleChangeSendsAgain() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000), now: 0)
        _ = rules.due(now: 200, headless: true, view: Self.virtualView, pipeline: nil)
        rules.set(Self.target(800, 500, backing: 1), now: 300)
        #expect(
            rules.due(
                now: 500, headless: true, view: View(width: 1600, height: 1000, scale: 2), pipeline: nil)
                == .resize(width: 800, height: 500, scale: 1))
    }

    @Test func aHugeScaleIsClamped() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000, backing: 8), now: 0)
        #expect(
            rules.due(now: 200, headless: true, view: Self.virtualView, pipeline: nil)
                == .resize(width: 1600, height: 1000, scale: 4))
    }

    /// Standard: half a side and half the scale, on a Retina display.
    @Test func aStandardVirtualScreenAsksForHalf() {
        var rules = ResizeRules()
        rules.set(Self.target(3024, 1964, resolution: .standard), now: 0)
        #expect(
            rules.due(now: 500, headless: true, view: Self.virtualView, pipeline: .gpu)
                == .resize(width: 1512, height: 982, scale: 1))
    }

    /// The remote desktop's layout (width ÷ scale) is the same either way: only its pixels
    /// change.
    @Test(arguments: [TextSize.mac, .f75, .f50])
    func theLayoutDoesNotChangeWithResolution(_ size: TextSize) throws {
        var layouts: [Float] = []
        for resolution in [VirtualResolution.retina, .standard] {
            var rules = ResizeRules()
            rules.set(Self.target(3024, 1964, factor: size.factor, resolution: resolution), now: 0)
            let message = rules.due(now: 500, headless: true, view: Self.virtualView, pipeline: nil)
            guard case .resize(let width, _, let scale) = try #require(message) else {
                Issue.record("not a Resize")
                return
            }
            layouts.append(Float(width) / scale)
        }
        #expect(layouts[0] == layouts[1])
    }

    @Test func aMirrorIgnoresResolution() {
        var rules = ResizeRules()
        rules.set(Self.target(3024, 1964, resolution: .standard), now: 0)
        #expect(
            rules.due(now: 500, headless: false, view: Self.mirrorView, pipeline: .cpu)
                == .resize(width: 3024, height: 1964, scale: 2))
    }

    /// Automatic asks for every pixel until the stream says its pipeline is the CPU's.
    @Test func automaticChangesWhenThePipelineIsKnown() {
        var rules = ResizeRules()
        rules.set(Self.target(3024, 1964, resolution: .automatic), now: 0)
        #expect(
            rules.due(now: 500, headless: true, view: Self.virtualView, pipeline: nil)
                == .resize(width: 3024, height: 1964, scale: 2))
        #expect(
            rules.due(now: 1000, headless: true, view: Self.virtualView, pipeline: .cpu)
                == .resize(width: 1512, height: 982, scale: 1))
    }
}

/// The core sends a Resize only while streaming.
@Suite struct CoreResizeTests {
    private static let target = ViewTarget(width: 1600, height: 1000, backingScale: 2, textFactor: 1)

    private func streaming() -> SessionCore {
        var core = HandshakeTests.core()
        _ = core.receive(HandshakeTests.helloAck(), payloadLength: 0, now: 0)
        _ = core.receive(.streamConfig(HandshakeTests.config), payloadLength: 0, now: 0)
        return core
    }

    /// A target before the first StreamConfig waits for it, and goes with it.
    @Test func aTargetBeforeStreamingGoesWithTheFirstStreamConfig() {
        var core = HandshakeTests.core()
        _ = core.receive(HandshakeTests.helloAck(), payloadLength: 0, now: 0)
        core.setViewTarget(Self.target, now: 0)
        #expect(core.resizeDue(now: 500).isEmpty)
        let actions = core.receive(.streamConfig(HandshakeTests.config), payloadLength: 0, now: 600)
        #expect(actions.contains(.send(.resize(width: 1600, height: 1000, scale: 2))))
    }

    /// The window's latest size is taken before the live-resize edges that came with it: a
    /// drag's end with its last size sends that size at once.
    @Test(arguments: [[false], [true, false]])
    func aDragsEndTakenWithItsLastSizeGoesAtOnce(edges: [Bool]) {
        var core = streaming()
        core.takeWindow(
            ViewTarget(width: 1400, height: 900, backingScale: 2, textFactor: 1), liveResizeEdges: [], now: 0)
        _ = core.resizeDue(now: 0)
        core.takeWindow(nil, liveResizeEdges: [true], now: 1000)
        core.takeWindow(Self.target, liveResizeEdges: edges, now: 1900)
        #expect(core.resizeDue(now: 1901) == [.send(.resize(width: 1600, height: 1000, scale: 2))])
    }

    /// The Resize goes ahead of the decoder's set-up, which awaits: a newer one can't pass it.
    @Test func theFirstStreamConfigsResizeGoesBeforeTheDecoder() {
        var core = HandshakeTests.core()
        _ = core.receive(HandshakeTests.helloAck(), payloadLength: 0, now: 0)
        core.setViewTarget(Self.target, now: 0)
        let actions = core.receive(.streamConfig(HandshakeTests.config), payloadLength: 0, now: 600)
        #expect(actions.first == .send(.resize(width: 1600, height: 1000, scale: 2)))
    }

    @Test func theCoreHoldsResizesDuringALiveResize() {
        var core = streaming()
        core.setLiveResize(true)
        core.setViewTarget(Self.target, now: 0)
        #expect(!core.tick(now: 2000).contains(.send(.resize(width: 1600, height: 1000, scale: 2))))
        core.setLiveResize(false)
        #expect(core.resizeDue(now: 2001) == [.send(.resize(width: 1600, height: 1000, scale: 2))])
    }

    /// Nothing after the end.
    @Test func nothingIsSentOnceFinished() {
        var core = streaming()
        core.setViewTarget(Self.target, now: 0)
        _ = core.stop()
        #expect(core.resizeDue(now: 500).isEmpty)
        #expect(core.tick(now: 500).isEmpty)
    }

    @Test func theTickSendsADueResize() {
        var core = streaming()
        core.setViewTarget(ViewTarget(width: 1400, height: 900, backingScale: 2, textFactor: 1), now: 0)
        _ = core.resizeDue(now: 0)
        core.setViewTarget(Self.target, now: 1000)
        #expect(!core.tick(now: 1100).contains(.send(.resize(width: 1600, height: 1000, scale: 2))))
        #expect(core.tick(now: 1200).contains(.send(.resize(width: 1600, height: 1000, scale: 2))))
    }

    @Test func aMirrorUsesTheBackingScaleAndAVirtualScreenTheText() {
        var core = HandshakeTests.core()
        let headless = SessionInfo(headless: true, output: "gliff-1")
        _ = core.receive(
            .helloAck(version: 1, session: headless, outputs: [], features: []), payloadLength: 0, now: 0)
        _ = core.receive(.streamConfig(HandshakeTests.config), payloadLength: 0, now: 0)
        core.setViewTarget(ViewTarget(width: 1600, height: 1000, backingScale: 2, textFactor: 0.75), now: 0)
        #expect(core.resizeDue(now: 200) == [.send(.resize(width: 1600, height: 1000, scale: 1.5))])
    }

    /// The server's quality ladder halved the stream (scale_milli 1000 for an output at 2×,
    /// upstream `stream_config`): the virtual screen is already 1600×1000 at 2×, so nothing goes.
    @Test func aLadderedStreamStillAnswersTheTarget() {
        var core = HandshakeTests.core()
        let headless = SessionInfo(headless: true, output: "gliff-1")
        _ = core.receive(
            .helloAck(version: 1, session: headless, outputs: [], features: []), payloadLength: 0, now: 0)
        var config = HandshakeTests.config
        (config.width, config.height, config.scaleMilli) = (800, 500, 1000)
        (config.viewWidth, config.viewHeight) = (1600, 1000)
        _ = core.receive(.streamConfig(config), payloadLength: 0, now: 0)
        core.setViewTarget(ViewTarget(width: 1600, height: 1000, backingScale: 2, textFactor: 1), now: 0)
        #expect(core.resizeDue(now: 200) == [])
    }
}
