import GliffProtocol
import GliffVideo
import Testing

@testable import GliffSession

/// The rules once video flows: StreamConfig checks, one ack per frame, the keyframe latch,
/// RTT pings and stats (upstream `net.rs`).
@Suite struct StreamingTests {
    private static let config = HandshakeTests.config

    /// A core that has just entered streaming with `config`.
    private func streaming(_ config: StreamConfig = Self.config) -> SessionCore {
        var core = HandshakeTests.core()
        _ = core.receive(HandshakeTests.helloAck(), payloadLength: 0, now: 0)
        _ = core.receive(.streamConfig(config), payloadLength: 0, now: 0)
        return core
    }

    private func frame(_ id: UInt64, keyframe: Bool = false, data: UInt32 = 1000, aux: UInt32 = 500)
        -> VideoFrameHeader
    {
        VideoFrameHeader(
            frameID: id, ptsMicroseconds: 0, isKeyframe: keyframe, damage: [], dataLength: data,
            auxLength: aux)
    }

    private func with(_ change: (inout StreamConfig) -> Void) -> StreamConfig {
        var config = Self.config
        change(&config)
        return config
    }

    @Test func firstValidConfigConfiguresDecoder() {
        var core = HandshakeTests.core()
        _ = core.receive(HandshakeTests.helloAck(), payloadLength: 0, now: 0)
        #expect(
            core.receive(.streamConfig(Self.config), payloadLength: 0, now: 0) == [
                .configureDecoder(Self.config), .status(.streaming(StreamInfo(Self.config))),
            ])
    }

    @Test(
        arguments: [
            { (c: inout StreamConfig) in c.width = 0 },
            { (c: inout StreamConfig) in c.width = 1281 },
            { (c: inout StreamConfig) in c.width = 4098 },
            { (c: inout StreamConfig) in c.viewWidth = 639 },
            { (c: inout StreamConfig) in c.codec = .h265 },
            { (c: inout StreamConfig) in c.chroma = .native444 },
        ] as [@Sendable (inout StreamConfig) -> Void])
    func invalidConfigs(change: @Sendable (inout StreamConfig) -> Void) {
        var core = HandshakeTests.core()
        _ = core.receive(HandshakeTests.helloAck(), payloadLength: 0, now: 0)
        let actions = core.receive(.streamConfig(with(change)), payloadLength: 0, now: 0)
        #expect(HandshakeTests.isProtocolError(actions), "\(actions)")
    }

    @Test func invalidReconfigEndsTheSession() {
        var core = streaming()
        let actions = core.receive(.streamConfig(with { $0.height = 4097 }), payloadLength: 0, now: 0)
        #expect(HandshakeTests.isProtocolError(actions), "\(actions)")
    }

    @Test func validLimitsPass() {
        #expect(
            StreamRules.validate(with { ($0.width, $0.height, $0.viewWidth, $0.viewHeight) = (2, 2, 2, 2) })
                == nil)
        #expect(
            StreamRules.validate(
                with { ($0.width, $0.height, $0.viewWidth, $0.viewHeight) = (4096, 4096, 4096, 4096) }) == nil
        )
        #expect(StreamRules.validate(with { ($0.viewWidth, $0.viewHeight) = (640, 360) }) == nil)
        #expect(StreamRules.validate(with { $0.chroma = .single420 }) == nil)
    }

    @Test(
        arguments: [
            { (c: inout StreamConfig) in c.fpsCap = 30 },
            { (c: inout StreamConfig) in (c.viewWidth, c.viewHeight) = (2560, 1440) },
            { (c: inout StreamConfig) in c.scaleMilli = 2000 },
            { (c: inout StreamConfig) in c.pipeline = .cpu },
        ] as [@Sendable (inout StreamConfig) -> Void])
    func paceOnlyChangeKeepsDecoder(change: @Sendable (inout StreamConfig) -> Void) {
        var core = streaming()
        let next = with(change)
        // The decoder keeps its sessions and only learns the new config (a new view box).
        #expect(
            core.receive(.streamConfig(next), payloadLength: 0, now: 0) == [
                .updateDecoder(next), .status(.streaming(StreamInfo(next))),
            ])
    }

    @Test(
        arguments: [
            { (c: inout StreamConfig) in c.width = 1920 },
            { (c: inout StreamConfig) in c.chroma = .single420 },
            { (c: inout StreamConfig) in c.extradata = [1] },
            { (c: inout StreamConfig) in c.auxExtradata = [2] },
        ] as [@Sendable (inout StreamConfig) -> Void])
    func codedChangeRebuilds(change: @Sendable (inout StreamConfig) -> Void) {
        var core = streaming()
        let next = with(change)
        #expect(
            core.receive(.streamConfig(next), payloadLength: 0, now: 0) == [
                .configureDecoder(next), .status(.streaming(StreamInfo(next))),
            ])
    }

    @Test func frameIsDecodedThenAckedOnce() {
        var core = streaming()
        let header = frame(1, keyframe: true)
        #expect(core.receive(.videoFrame(header), payloadLength: 1500, now: 0) == [.decode(header)])
        #expect(
            core.decoded(frameID: 1, outcome: .noPicture, decodeMilliseconds: 3, now: 1000) == [
                .send(.frameAck(frameID: 1, decodedAtMilliseconds: 1000))
            ])
        #expect(core.decoded(frameID: 1, outcome: .noPicture, decodeMilliseconds: 3, now: 1001) == [])
    }

    @Test func failedDecodeRequestsOneKeyframe() {
        var core = streaming()
        func send(_ id: UInt64, keyframe: Bool = false) {
            _ = core.receive(.videoFrame(frame(id, keyframe: keyframe)), payloadLength: 1500, now: 0)
        }
        func decoded(_ id: UInt64, _ outcome: DecodeOutcome = .failed("bad")) -> [SessionAction] {
            core.decoded(frameID: id, outcome: outcome, decodeMilliseconds: 1, now: 5)
        }
        let ack = { (id: UInt64) in SessionAction.send(.frameAck(frameID: id, decodedAtMilliseconds: 5)) }
        for id: UInt64 in 1...3 { send(id) }
        #expect(decoded(1) == [ack(1), .send(.requestKeyframe)])
        #expect(decoded(2) == [ack(2)])
        #expect(decoded(3) == [ack(3)])
        // The keyframe fails too: ask again, once.
        send(4, keyframe: true)
        #expect(decoded(4) == [ack(4), .send(.requestKeyframe)])
        send(5)
        #expect(decoded(5) == [ack(5)])
        // A keyframe that decodes clears the latch: the next failure asks again.
        send(6, keyframe: true)
        #expect(decoded(6, .picture) == [ack(6)])
        send(7)
        #expect(decoded(7) == [ack(7), .send(.requestKeyframe)])
    }

    @Test func payloadShorterThanDeclared() {
        var short = streaming()
        let actions = short.receive(.videoFrame(frame(1)), payloadLength: 1400, now: 0)
        #expect(HandshakeTests.isProtocolError(actions), "\(actions)")
        var long = streaming()
        #expect(long.receive(.videoFrame(frame(1)), payloadLength: 1600, now: 0) == [.decode(frame(1))])
    }

    @Test func decodedForUnknownFrameIsIgnored() {
        var core = streaming()
        #expect(core.decoded(frameID: 9, outcome: .picture, decodeMilliseconds: 1, now: 5) == [])
    }

    /// The session validates it with the frame's payload (`CursorImage`).
    @Test func aCursorShapeWhileStreamingIsHandedOn() {
        var core = streaming()
        let shape = CursorShape(id: 1, width: 2, height: 2, hotX: 0, hotY: 0, argbLength: 16)
        #expect(core.receive(.cursorShape(shape), payloadLength: 16, now: 0) == [.cursor(shape)])
        let bad = CursorShape(id: 2, width: 2, height: 2, hotX: 0, hotY: 0, argbLength: 15)
        #expect(core.receive(.cursorShape(bad), payloadLength: 15, now: 0) == [.cursor(bad)])
    }

    @Test func aCursorPositionWhileStreamingIsPassedOn() {
        var core = streaming()
        #expect(
            core.receive(.cursorPosition(x: 10, y: 20, shapeID: 1, visible: true), payloadLength: 0, now: 0)
                == [.cursorPosition(x: 10, y: 20, visible: true)])
    }

    @Test(arguments: [(Double.nan, 1.0), (1, .infinity), (-.infinity, 1)])
    func aCursorPositionThatIsNoNumberIsDropped(x: Double, y: Double) {
        var core = streaming()
        #expect(
            core.receive(.cursorPosition(x: x, y: y, shapeID: 1, visible: true), payloadLength: 0, now: 0)
                == [])
        #expect(!core.isFinished)
    }

    /// In capture-buffer pixels, which may be more than the stream's (a picture shrunk to the
    /// Mac's display): the server's own `visible` says whether it is on the screen.
    @Test func aCursorPositionPastTheStreamsSizeIsPassedOnAsSent() {
        var core = streaming()
        let width = Double(Self.config.width)
        #expect(
            core.receive(
                .cursorPosition(x: width + 1, y: 2, shapeID: 1, visible: true), payloadLength: 0, now: 0)
                == [.cursorPosition(x: width + 1, y: 2, visible: true)])
    }

    @Test func aPongIsNotPassedOn() {
        var core = streaming()
        #expect(core.receive(.pong(t: 1, serverNowMilliseconds: 2), payloadLength: 0, now: 0) == [])
        #expect(!core.isFinished)
    }

    @Test func rttPing() {
        var core = streaming()
        #expect(core.tick(now: 10_000).contains(.send(.ping(t: 10_000))))
        #expect(!core.tick(now: 11_999).contains { if case .send(.ping) = $0 { true } else { false } })
        #expect(core.tick(now: 12_000).contains(.send(.ping(t: 12_000))))
        #expect(core.receive(.pong(t: 10_000, serverNowMilliseconds: 0), payloadLength: 0, now: 10_042) == [])
        #expect(core.receive(.pong(t: 55, serverNowMilliseconds: 0), payloadLength: 0, now: 12_500) == [])
        let stats = core.tick(now: 13_000).compactMap {
            if case .status(.stats(let s)) = $0 { s } else { nil }
        }
        #expect(stats.map(\.roundTripMilliseconds) == [42])
    }

    /// The window opens with the first frame or the first tick, whichever comes first, so a
    /// burst of frames before any tick still counts.
    @Test(arguments: [true, false])
    func statsEverySecond(tickFirst: Bool) {
        var core = streaming()
        if tickFirst { _ = core.tick(now: 0) }
        for id: UInt64 in 1...30 {
            _ = core.receive(.videoFrame(frame(id, data: 2000, aux: 0)), payloadLength: 2000, now: 0)
            _ = core.decoded(frameID: id, outcome: .picture, decodeMilliseconds: 3, now: 0)
        }
        #expect(
            core.tick(now: 1000).contains(
                .status(
                    .stats(
                        SessionStats(
                            framesPerSecond: 30, megabitsPerSecond: 0.48, roundTripMilliseconds: nil,
                            decodeMilliseconds: 3)))))
    }

    /// Every VideoFrame gets its ack, even when the server repeats an id.
    @Test func repeatedFrameIDIsAckedEachTime() {
        var core = streaming()
        let ack = SessionAction.send(.frameAck(frameID: 7, decodedAtMilliseconds: 5))
        #expect(core.receive(.videoFrame(frame(7)), payloadLength: 1500, now: 0) == [.decode(frame(7))])
        #expect(core.receive(.videoFrame(frame(7)), payloadLength: 1500, now: 0) == [.decode(frame(7))])
        #expect(core.decoded(frameID: 7, outcome: .picture, decodeMilliseconds: 1, now: 5) == [ack])
        #expect(core.decoded(frameID: 7, outcome: .picture, decodeMilliseconds: 1, now: 5) == [ack])
        #expect(core.decoded(frameID: 7, outcome: .picture, decodeMilliseconds: 1, now: 5) == [])
    }

    /// Each Ping's `t` is its own, so its Pong names it alone (`FenceLedger`): a Ping in the
    /// same millisecond as the last, or just after a small step back, counts on from it.
    @Test func eachPingHasItsOwnT() {
        var core = streaming()
        #expect(core.pingNow(now: 10_000) == .send(.ping(t: 10_000)))
        #expect(core.pingNow(now: 10_000) == .send(.ping(t: 10_001)))
        #expect(core.pingNow(now: 9_999) == .send(.ping(t: 10_002)))
        #expect(core.pingNow(now: 10_005) == .send(.ping(t: 10_005)))
    }

    /// `now` is the wall clock: a step backwards gives no RTT sample and no stats over a
    /// negative window. A step back of a ping interval or more pings at the new time.
    @Test func clockStepBackIsNotMeasured() {
        var core = streaming()
        #expect(core.tick(now: 10_000) == [.send(.ping(t: 10_000))])
        #expect(core.tick(now: 8_000) == [.send(.ping(t: 8_000))])
        #expect(core.receive(.pong(t: 10_000, serverNowMilliseconds: 0), payloadLength: 0, now: 8_040) == [])
        let stats = core.tick(now: 10_000).compactMap {
            if case .status(.stats(let s)) = $0 { s } else { nil }
        }
        #expect(
            stats == [
                SessionStats(
                    framesPerSecond: 0, megabitsPerSecond: 0, roundTripMilliseconds: nil,
                    decodeMilliseconds: 0)
            ])
    }

    /// As upstream: fps and decode time count pictures; bandwidth counts every frame received.
    @Test func onlyPicturesCountAsFrames() {
        var core = streaming()
        _ = core.tick(now: 0)
        let outcomes: [DecodeOutcome] = [.picture, .failed("bad"), .picture, .noPicture]
        for (index, outcome) in outcomes.enumerated() {
            let id = UInt64(index + 1)
            _ = core.receive(.videoFrame(frame(id, data: 2500, aux: 0)), payloadLength: 2500, now: 0)
            _ = core.decoded(frameID: id, outcome: outcome, decodeMilliseconds: Double(index + 1), now: 0)
        }
        #expect(
            core.tick(now: 1000).contains(
                .status(
                    .stats(
                        SessionStats(
                            framesPerSecond: 2, megabitsPerSecond: 0.08, roundTripMilliseconds: nil,
                            decodeMilliseconds: 2)))))
    }

    @Test func noTicksBeforeStreaming() {
        var core = HandshakeTests.core()
        #expect(core.tick(now: 5000) == [])
        _ = core.receive(HandshakeTests.helloAck(), payloadLength: 0, now: 0)
        #expect(core.tick(now: 5000) == [])
    }
}
