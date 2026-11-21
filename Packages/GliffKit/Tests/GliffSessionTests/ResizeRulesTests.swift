import GliffProtocol
import Testing

@testable import GliffSession

/// When the window's size and scale go to the server as a Resize (upstream
/// `request_resize`, plus a settle delay).
@Suite struct ResizeRulesTests {
    private typealias View = ResizeRules.View

    private static func target(
        _ width: UInt32, _ height: UInt32, backing: Double = 2, factor: Double = 1
    ) -> ViewTarget {
        ViewTarget(width: width, height: height, backingScale: backing, textFactor: factor)
    }

    private static let mirrorView = View(width: 2560, height: 1440, scale: 1)
    private static let virtualView = View(width: 1920, height: 1080, scale: 1)

    @Test func nothingBeforeItSettles() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000), now: 0)
        #expect(rules.due(now: 199, headless: true, view: Self.virtualView) == nil)
        #expect(
            rules.due(now: 200, headless: true, view: Self.virtualView)
                == .resize(width: 1600, height: 1000, scale: 2))
    }

    /// A scale that isn't a number would never equal what was sent: it would go every tick.
    @Test(arguments: [(Double.nan, 1.0), (2, .nan), (.infinity, 1), (2, -.infinity)])
    func aScaleThatIsNotANumberIsNeverSent(backing: Double, factor: Double) {
        for headless in [true, false] {
            var rules = ResizeRules()
            rules.set(Self.target(1600, 1000, backing: backing, factor: factor), now: 0)
            #expect(rules.due(now: 500, headless: headless, view: Self.virtualView) == nil)
        }
    }

    /// A live drag sends once, when it pauses.
    @Test func aDragSendsOnceItSettles() {
        var rules = ResizeRules()
        var sent: [ClientMessage] = []
        var now: UInt64 = 0
        for step in 0...25 {
            rules.set(Self.target(1000 + UInt32(step) * 16, 600 + UInt32(step) * 12), now: now)
            if let message = rules.due(now: now, headless: true, view: Self.virtualView) {
                sent.append(message)
            }
            now += 16
        }
        let last = now - 16
        #expect(rules.due(now: last + 199, headless: true, view: Self.virtualView) == nil)
        if let message = rules.due(now: last + 200, headless: true, view: Self.virtualView) {
            sent.append(message)
        }
        #expect(rules.due(now: last + 900, headless: true, view: Self.virtualView) == nil)
        #expect(sent == [.resize(width: 1400, height: 900, scale: 2)])
    }

    @Test func theSameRequestIsNotSentTwice() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000), now: 0)
        #expect(rules.due(now: 200, headless: true, view: Self.virtualView) != nil)
        rules.set(Self.target(1600, 1000), now: 300)
        #expect(rules.due(now: 600, headless: true, view: Self.virtualView) == nil)
    }

    @Test func theServersViewIsNotRequested() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000), now: 0)
        #expect(rules.due(now: 200, headless: true, view: View(width: 1600, height: 1000, scale: 2)) == nil)
        // A mirror ignores the scale: its view alone decides.
        #expect(rules.due(now: 200, headless: false, view: View(width: 1600, height: 1000, scale: 1)) == nil)
    }

    /// The server rounds a virtual screen's mode (`clean_mode`); its answer
    /// sends nothing more.
    @Test func aRoundedViewDoesNotSendAgain() {
        var rules = ResizeRules()
        rules.set(Self.target(1366, 768, backing: 1.25), now: 0)
        #expect(
            rules.due(now: 200, headless: true, view: Self.virtualView)
                == .resize(width: 1366, height: 768, scale: 1.25))
        #expect(rules.due(now: 900, headless: true, view: View(width: 1360, height: 760, scale: 1.25)) == nil)
    }

    @Test(arguments: [(319, 600), (800, 239), (0, 0)] as [(UInt32, UInt32)])
    func tooSmallIsNotSent(width: UInt32, height: UInt32) {
        var rules = ResizeRules()
        rules.set(Self.target(width, height), now: 0)
        #expect(rules.due(now: 200, headless: true, view: Self.virtualView) == nil)
    }

    @Test func aVirtualScreenGetsTheTextFactor() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000, factor: 0.75), now: 0)
        #expect(
            rules.due(now: 200, headless: true, view: Self.virtualView)
                == .resize(width: 1600, height: 1000, scale: 1.5))
    }

    @Test func aMirrorGetsTheBackingScale() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000, factor: 0.75), now: 0)
        #expect(
            rules.due(now: 200, headless: false, view: Self.mirrorView)
                == .resize(width: 1600, height: 1000, scale: 2))
    }

    /// A 1× display, smaller text: the remote scale stays 1.
    @Test func aOneTimesDisplayNeverGoesBelowScaleOne() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000, backing: 1, factor: 0.5), now: 0)
        #expect(
            rules.due(now: 200, headless: true, view: Self.virtualView)
                == .resize(width: 1600, height: 1000, scale: 1))
    }

    @Test func aTextFactorChangeSendsTheSameSizeAtTheNewScale() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000), now: 0)
        _ = rules.due(now: 200, headless: true, view: Self.virtualView)
        rules.set(Self.target(1600, 1000, factor: 0.875), now: 300)
        #expect(
            rules.due(now: 500, headless: true, view: View(width: 1600, height: 1000, scale: 2))
                == .resize(width: 1600, height: 1000, scale: 1.75))
    }

    /// The window moves to a display of another backing scale.
    @Test func aBackingScaleChangeSendsAgain() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000), now: 0)
        _ = rules.due(now: 200, headless: true, view: Self.virtualView)
        rules.set(Self.target(800, 500, backing: 1), now: 300)
        #expect(
            rules.due(now: 500, headless: true, view: View(width: 1600, height: 1000, scale: 2))
                == .resize(width: 800, height: 500, scale: 1))
    }

    @Test func aHugeScaleIsClamped() {
        var rules = ResizeRules()
        rules.set(Self.target(1600, 1000, backing: 8), now: 0)
        #expect(
            rules.due(now: 200, headless: true, view: Self.virtualView)
                == .resize(width: 1600, height: 1000, scale: 4))
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

    /// A target before the first StreamConfig waits for it.
    @Test func aResizeGoesOnlyWhileStreaming() {
        var core = HandshakeTests.core()
        _ = core.receive(HandshakeTests.helloAck(), payloadLength: 0, now: 0)
        core.setViewTarget(Self.target, now: 0)
        #expect(core.resizeDue(now: 500).isEmpty)
        _ = core.receive(.streamConfig(HandshakeTests.config), payloadLength: 0, now: 600)
        #expect(core.resizeDue(now: 600) == [.send(.resize(width: 1600, height: 1000, scale: 2))])
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
