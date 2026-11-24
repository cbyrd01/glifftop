import GliffProtocol
import GliffVideo
import Testing

@testable import GliffSession

/// A virtual screen's first picture waits for the answer to its Resize: the server starts the
/// screen at its own default (1920×1080 at 1), which the window's size then replaces.
@Suite struct PictureHoldTests {
    static let target = ViewTarget(width: 1600, height: 1000, backingScale: 2, textFactor: 1)
    static let resize = SessionAction.send(.resize(width: 1600, height: 1000, scale: 2))
    static let first = config(1920, 1080, scaleMilli: 1000)
    static let answer = config(1600, 1000, scaleMilli: 2000)

    static func config(_ width: UInt32, _ height: UInt32, scaleMilli: UInt32) -> StreamConfig {
        StreamConfig(
            codec: .h264, chroma: .dual420, pipeline: .gpu, width: width, height: height,
            scaleMilli: scaleMilli,
            extradata: [], auxExtradata: nil, viewWidth: width, viewHeight: height, fpsCap: 60)
    }

    static func handshaken(headless: Bool = true) -> SessionCore {
        var core = HandshakeTests.core()
        _ = core.receive(HandshakeTests.helloAck(headless: headless), payloadLength: 0, now: 0)
        return core
    }

    /// The `pictureHeld` statuses among `actions`, in order.
    static func held(_ actions: [SessionAction]) -> [Bool] {
        actions.compactMap { if case .status(.pictureHeld(let on)) = $0 { on } else { nil } }
    }

    static func frame(_ id: UInt64) -> ServerMessage {
        .videoFrame(
            VideoFrameHeader(
                frameID: id, ptsMicroseconds: 0, isKeyframe: id == 1, damage: [], dataLength: 0, auxLength: 0)
        )
    }

    /// A frame received and decoded to a picture: whether that showed the picture.
    static func shows(_ core: inout SessionCore, frame id: UInt64, at now: UInt64) -> [Bool] {
        _ = core.receive(frame(id), payloadLength: 0, now: now)
        return held(core.decoded(frameID: id, outcome: .picture, decodeMilliseconds: 1, now: now))
    }

    /// Held from the first StreamConfig until a picture of the answer: the slot still has the
    /// old picture when the answer's StreamConfig arrives.
    @Test func aVirtualScreenIsHeldUntilItsResizeIsAnswered() {
        var core = Self.handshaken()
        core.setViewTarget(Self.target, now: 0)
        let actions = core.receive(.streamConfig(Self.first), payloadLength: 0, now: 100)
        #expect(Self.held(actions) == [true])
        #expect(actions.contains(Self.resize))
        let heldAt = actions.firstIndex(of: .status(.pictureHeld(true)))
        let streamingAt = actions.firstIndex { if case .status(.streaming) = $0 { true } else { false } }
        #expect(heldAt != nil && streamingAt != nil && heldAt! < streamingAt!)
        #expect(Self.shows(&core, frame: 1, at: 150).isEmpty)
        _ = core.receive(Self.frame(2), payloadLength: 0, now: 200)
        #expect(Self.held(core.receive(.streamConfig(Self.answer), payloadLength: 0, now: 400)).isEmpty)
        // A frame from before the answer, decoded after it, is still the old picture.
        #expect(
            Self.held(core.decoded(frameID: 2, outcome: .picture, decodeMilliseconds: 1, now: 410)).isEmpty)
        #expect(Self.shows(&core, frame: 3, at: 450) == [false])
    }

    /// A StreamConfig with the same view (a quality step) isn't the answer.
    @Test func aStreamConfigWithTheSameViewKeepsTheHold() {
        var core = Self.handshaken()
        core.setViewTarget(Self.target, now: 0)
        _ = core.receive(.streamConfig(Self.first), payloadLength: 0, now: 100)
        var laddered = Self.first
        (laddered.width, laddered.height, laddered.scaleMilli) = (960, 540, 500)
        #expect(Self.held(core.receive(.streamConfig(laddered), payloadLength: 0, now: 300)).isEmpty)
        #expect(Self.shows(&core, frame: 1, at: 350).isEmpty)
    }

    /// The answer's first frame that doesn't decode: the next picture shows it.
    @Test func anAnswerWhoseFirstFrameFailsShowsWithTheNext() {
        var core = Self.handshaken()
        core.setViewTarget(Self.target, now: 0)
        _ = core.receive(.streamConfig(Self.first), payloadLength: 0, now: 100)
        _ = core.receive(.streamConfig(Self.answer), payloadLength: 0, now: 400)
        _ = core.receive(Self.frame(1), payloadLength: 0, now: 450)
        #expect(
            Self.held(core.decoded(frameID: 1, outcome: .failed("test"), decodeMilliseconds: 1, now: 460))
                .isEmpty)
        #expect(Self.shows(&core, frame: 2, at: 500) == [false])
    }

    /// The server ignores a Resize it finds unchanged: the picture shows 2 s after the first.
    @Test func anUnansweredResizeShowsThePictureAfterTwoSeconds() {
        var core = Self.handshaken()
        core.setViewTarget(Self.target, now: 0)
        _ = core.receive(.streamConfig(Self.first), payloadLength: 0, now: 100)
        #expect(Self.held(core.tick(now: 900)).isEmpty)
        _ = core.receive(Self.frame(1), payloadLength: 0, now: 1000)
        _ = core.receive(Self.frame(2), payloadLength: 0, now: 1500)
        #expect(Self.held(core.tick(now: 2999)).isEmpty)
        #expect(Self.held(core.tick(now: 3000)) == [false])
        #expect(Self.held(core.tick(now: 4000)).isEmpty)
    }

    /// A Resize that goes after the first frame gets its own 2 s.
    @Test func theLimitCountsFromALateResize() {
        var core = Self.handshaken()
        _ = core.receive(.streamConfig(Self.first), payloadLength: 0, now: 100)
        _ = core.receive(Self.frame(1), payloadLength: 0, now: 150)
        core.setViewTarget(Self.target, now: 2000)
        #expect(core.resizeDue(now: 2000) == [Self.resize])
        #expect(Self.held(core.tick(now: 2200)).isEmpty)
        #expect(Self.held(core.tick(now: 4000)) == [false])
    }

    @Test func aTargetEqualToTheFirstViewIsNotHeld() {
        var core = Self.handshaken()
        core.setViewTarget(ViewTarget(width: 1920, height: 1080, backingScale: 1, textFactor: 1), now: 0)
        let actions = core.receive(.streamConfig(Self.first), payloadLength: 0, now: 100)
        #expect(Self.held(actions).isEmpty)
    }

    @Test func aMirrorIsNeverHeld() {
        var core = Self.handshaken(headless: false)
        let actions = core.receive(.streamConfig(Self.first), payloadLength: 0, now: 100)
        core.setViewTarget(Self.target, now: 200)
        let later =
            core.resizeDue(now: 200) + core.receive(.streamConfig(Self.answer), payloadLength: 0, now: 400)
        #expect(Self.held(actions + later).isEmpty)
        #expect(Self.shows(&core, frame: 1, at: 450).isEmpty)
    }

    @Test func aLaterResizeIsNotHeld() {
        var core = Self.handshaken()
        core.setViewTarget(Self.target, now: 0)
        _ = core.receive(.streamConfig(Self.first), payloadLength: 0, now: 100)
        _ = core.receive(.streamConfig(Self.answer), payloadLength: 0, now: 400)
        #expect(Self.shows(&core, frame: 1, at: 450) == [false])
        core.setViewTarget(ViewTarget(width: 1400, height: 900, backingScale: 2, textFactor: 1), now: 1000)
        let sent = core.resizeDue(now: 1200)
        let answered = core.receive(
            .streamConfig(Self.config(1400, 900, scaleMilli: 2000)), payloadLength: 0, now: 1500)
        #expect(sent == [.send(.resize(width: 1400, height: 900, scale: 2))])
        #expect(Self.held(sent + answered).isEmpty)
        #expect(Self.shows(&core, frame: 2, at: 1550).isEmpty)
    }

    /// The window's size not known yet at the first StreamConfig: held until it is answered.
    @Test func noTargetYetHoldsUntilOneIsAnswered() {
        var core = Self.handshaken()
        #expect(Self.held(core.receive(.streamConfig(Self.first), payloadLength: 0, now: 100)) == [true])
        core.setViewTarget(Self.target, now: 200)
        #expect(core.resizeDue(now: 200) == [Self.resize])
        #expect(Self.held(core.receive(.streamConfig(Self.answer), payloadLength: 0, now: 400)).isEmpty)
        #expect(Self.shows(&core, frame: 1, at: 450) == [false])
    }

    /// A size that arrives equal to the server's view leaves nothing to wait for.
    @Test func aLateTargetEqualToTheViewShowsThePicture() {
        var core = Self.handshaken()
        _ = core.receive(.streamConfig(Self.first), payloadLength: 0, now: 100)
        core.setViewTarget(ViewTarget(width: 1920, height: 1080, backingScale: 1, textFactor: 1), now: 200)
        #expect(Self.held(core.resizeDue(now: 200)) == [false])
    }

    /// Shown by a StreamConfig's batch: after its stream, so the app never shows the old one.
    @Test func aPictureShownWithAStreamConfigShowsAfterItsStream() {
        var core = Self.handshaken()
        _ = core.receive(.streamConfig(Self.first), payloadLength: 0, now: 100)
        core.setViewTarget(ViewTarget(width: 1920, height: 1080, backingScale: 1, textFactor: 1), now: 200)
        var laddered = Self.first
        (laddered.width, laddered.height, laddered.scaleMilli) = (960, 540, 500)
        let actions = core.receive(.streamConfig(laddered), payloadLength: 0, now: 300)
        #expect(Self.held(actions) == [false])
        #expect(actions.last == .status(.pictureHeld(false)))
    }
}
