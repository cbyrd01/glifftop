import GliffProtocol
import GliffTransport
import Testing

@testable import GliffSession

/// The handshake rules, as upstream's client (`net.rs`) applies them.
@Suite struct HandshakeTests {
    static let session = SessionInfo(headless: false, output: "FAKE-1")
    static let output = OutputInfo(name: "FAKE-1", width: 1280, height: 720, scaleMilli: 1000)
    static let config = StreamConfig(
        codec: .h264, chroma: .dual420, pipeline: .gpu, width: 1280, height: 720, scaleMilli: 1000,
        extradata: [], auxExtradata: nil, viewWidth: 1280, viewHeight: 720, fpsCap: 60)

    static func core(features: [String: Set<Int64>] = [:]) -> SessionCore {
        var core = SessionCore(
            configuration: SessionConfiguration(maxWidth: 5120, maxHeight: 2880), features: features)
        _ = core.start()
        return core
    }

    /// Exactly one action: finishing with a protocol error.
    static func isProtocolError(_ actions: [SessionAction]) -> Bool {
        if actions.count == 1, case .finish(.protocolError) = actions[0] { true } else { false }
    }

    static func helloAck(
        version: UInt16 = 1, features: [String] = [], outputs: [OutputInfo] = [output], headless: Bool = false
    ) -> ServerMessage {
        let session = headless ? SessionInfo(headless: true, output: "gliff-1") : session
        return .helloAck(version: version, session: session, outputs: outputs, features: features)
    }

    @Test func startSendsHello() {
        var core = SessionCore(
            configuration: SessionConfiguration(maxWidth: 5120, maxHeight: 2880), features: [:])
        let caps = ClientCaps(
            codecs: [.h264], maxWidth: 4096, maxHeight: 2880, chroma: [.dual420, .single420], features: [])
        #expect(core.start() == [.status(.handshaking), .send(.hello(version: 1, keymap: "", caps: caps))])
    }

    @Test func featuresAreSortedNames() {
        var core = SessionCore(
            configuration: SessionConfiguration(maxWidth: 1280, maxHeight: 720), features: ["b": [], "a": []])
        guard case .send(.hello(_, _, let caps)) = core.start().last else {
            Issue.record("no Hello")
            return
        }
        #expect(caps.features == ["a", "b"])
    }

    @Test func pingIsAnsweredInEveryState() {
        var core = Self.core()
        #expect(core.receive(.ping(t: 7), payloadLength: 0, now: 0).first == .send(.pong(t: 7)))
        _ = core.receive(Self.helloAck(), payloadLength: 0, now: 0)
        #expect(core.receive(.ping(t: 7), payloadLength: 0, now: 0).first == .send(.pong(t: 7)))
        _ = core.receive(.streamConfig(Self.config), payloadLength: 0, now: 0)
        #expect(core.receive(.ping(t: 7), payloadLength: 0, now: 0).first == .send(.pong(t: 7)))
    }

    @Test func helloAckWaitsForVideo() {
        var core = Self.core(features: ["a": [], "b": []])
        #expect(
            core.receive(Self.helloAck(features: ["c", "a"]), payloadLength: 0, now: 0) == [
                .status(.waitingForVideo(Self.session, Self.output)), .activate(features: ["a"]),
            ])
        var plain = Self.core(features: ["b": []])
        #expect(
            plain.receive(Self.helloAck(features: ["a", "c"]), payloadLength: 0, now: 0) == [
                .status(.waitingForVideo(Self.session, Self.output))
            ])
    }

    /// A mirror's window is sized from its monitor, the HelloAck output named by the
    /// session.
    @Test func helloAckReportsTheSessionsOutput() {
        var core = Self.core()
        let other = OutputInfo(name: "HEADLESS-9", width: 1920, height: 1080, scaleMilli: 1000)
        let own = OutputInfo(name: "FAKE-1", width: 2560, height: 1440, scaleMilli: 1250)
        #expect(
            core.receive(Self.helloAck(outputs: [other, own]), payloadLength: 0, now: 0) == [
                .status(.waitingForVideo(Self.session, own))
            ])
    }

    @Test func anOutputNotListedIsNil() {
        var core = Self.core()
        let other = OutputInfo(name: "HEADLESS-9", width: 1920, height: 1080, scaleMilli: 1000)
        #expect(
            core.receive(Self.helloAck(outputs: [other]), payloadLength: 0, now: 0) == [
                .status(.waitingForVideo(Self.session, nil))
            ])
    }

    /// The output sizes the window for the whole session: one with no area, or far past any
    /// monitor, is not used (the first StreamConfig's view, which is checked, is).
    @Test(arguments: [(0, 1440), (2560, 0), (16385, 1440), (2560, 16385)])
    func anImpossibleOutputSizeIsNil(width: UInt32, height: UInt32) {
        var core = Self.core()
        let own = OutputInfo(name: "FAKE-1", width: width, height: height, scaleMilli: 1000)
        #expect(
            core.receive(Self.helloAck(outputs: [own]), payloadLength: 0, now: 0) == [
                .status(.waitingForVideo(Self.session, nil))
            ])
    }

    @Test func aLargeMonitorIsKept() {
        var core = Self.core()
        let own = OutputInfo(name: "FAKE-1", width: 7680, height: 4320, scaleMilli: 2000)
        #expect(
            core.receive(Self.helloAck(outputs: [own]), payloadLength: 0, now: 0) == [
                .status(.waitingForVideo(Self.session, own))
            ])
    }

    @Test func wrongVersionIsIncompatible() {
        var core = Self.core()
        #expect(
            core.receive(Self.helloAck(version: 2), payloadLength: 0, now: 0) == [
                .finish(
                    .incompatible("The server speaks Gliff protocol v2; Glifftop speaks v1. Update Glifftop.")
                )
            ])
        #expect(core.isFinished)
        #expect(core.receive(.ping(t: 1), payloadLength: 0, now: 0) == [])
    }

    @Test func streamConfigBeforeHelloAck() {
        var core = Self.core()
        let actions = core.receive(.streamConfig(Self.config), payloadLength: 0, now: 0)
        #expect(Self.isProtocolError(actions), "\(actions)")
    }

    @Test func videoFrameBeforeStreamConfig() {
        var core = Self.core()
        _ = core.receive(Self.helloAck(), payloadLength: 0, now: 0)
        let frame = VideoFrameHeader(
            frameID: 1, ptsMicroseconds: 0, isKeyframe: true, damage: [], dataLength: 0, auxLength: 0)
        let actions = core.receive(.videoFrame(frame), payloadLength: 0, now: 0)
        #expect(Self.isProtocolError(actions), "\(actions)")
    }

    /// Upstream bails on anything else before StreamConfig ("unexpected message"); its server
    /// sends the first StreamConfig before any cursor.
    @Test(arguments: [
        ServerMessage.cursorPosition(x: 0, y: 0, shapeID: 0, visible: true),
        .cursorShape(CursorShape(id: 1, width: 1, height: 1, hotX: 0, hotY: 0, argbLength: 4)),
    ])
    func cursorBeforeStreamConfigIsAProtocolError(message: ServerMessage) {
        var core = Self.core()
        _ = core.receive(Self.helloAck(), payloadLength: 0, now: 0)
        let actions = core.receive(message, payloadLength: 4, now: 0)
        #expect(Self.isProtocolError(actions), "\(actions)")
    }

    @Test(arguments: [
        (UInt16(1), SessionEnd.incompatible("nope")),
        (UInt16(2), SessionEnd.incompatible("nope")),
        (UInt16(256), SessionEnd.serverSetupFailed("nope")),
        (UInt16(300), SessionEnd.serverError(code: 300, message: "nope")),
    ])
    func errorCodes(code: UInt16, end: SessionEnd) {
        var core = Self.core()
        #expect(
            core.receive(.error(code: code, message: "nope", version: nil), payloadLength: 0, now: 0) == [
                .finish(end)
            ])
    }

    @Test func unknownIsSkippedInEveryState() {
        var core = Self.core()
        #expect(core.receive(.unknown(variant: 50), payloadLength: 4, now: 0) == [])
        _ = core.receive(Self.helloAck(), payloadLength: 0, now: 0)
        #expect(core.receive(.unknown(variant: 50), payloadLength: 4, now: 0) == [])
        #expect(!core.isFinished)
    }

    @Test func endedBy() {
        var core = Self.core()
        #expect(
            core.ended(by: TransportError.exited(status: 255, failure: .permissionDenied), afterFrames: 0)
                == [
                    .finish(.connectFailed(.permissionDenied))
                ])
        var banner = Self.core()
        #expect(
            banner.ended(by: ProtocolError.bodyTooLarge(0x636c_6557), afterFrames: 0) == [
                .finish(.remoteNotGliff)
            ])
        var dropped = Self.core()
        _ = dropped.receive(Self.helloAck(), payloadLength: 0, now: 0)
        #expect(dropped.ended(by: nil, afterFrames: 2) == [.finish(.connectionLost)])
        var stopped = Self.core()
        _ = stopped.stop()
        #expect(stopped.ended(by: nil, afterFrames: 2) == [])
    }

    /// A transport whose connect fails (a shared connection's sign-in) fails before the Hello
    /// goes: still a failure to connect, with ssh's reason, not a lost link.
    @Test func aConnectThatFailsIsAFailureToConnect() {
        var core = SessionCore(
            configuration: SessionConfiguration(maxWidth: 5120, maxHeight: 2880), features: [:])
        #expect(
            core.ended(by: TransportError.exited(status: 255, failure: .unknownHostKey), afterFrames: 0) == [
                .finish(.connectFailed(.unknownHostKey))
            ])
    }

    /// Before the session starts there is no reader to bring ssh's exit: a write failure ends
    /// it as a failure to connect.
    @Test func aWriteFailureBeforeTheStartEndsTheConnect() {
        var core = SessionCore(
            configuration: SessionConfiguration(maxWidth: 5120, maxHeight: 2880), features: [:])
        #expect(
            core.ended(by: TransportError.writeFailed("Broken pipe"), afterFrames: 0) == [
                .finish(.connectFailed(.other("Broken pipe")))
            ])
    }

    @Test func protocolErrorAfterTheFirstFrameIsNotABanner() {
        var core = Self.core()
        let actions = core.ended(by: ProtocolError.bodyTooLarge(1 << 21), afterFrames: 3)
        #expect(Self.isProtocolError(actions), "\(actions)")
    }

    /// The writer's EPIPE can beat the reader's classified ssh exit: before HelloAck it waits
    /// for that exit, so a changed host key isn't reported as a lost connection.
    @Test func writeFailureBeforeHelloAckWaitsForTheExit() {
        var core = Self.core()
        #expect(core.ended(by: TransportError.writeFailed("Broken pipe"), afterFrames: 0) == [])
        #expect(
            core.ended(by: TransportError.exited(status: 255, failure: .changedHostKey()), afterFrames: 0)
                == [
                    .finish(.connectFailed(.changedHostKey()))
                ])
        var streaming = Self.core()
        _ = streaming.receive(Self.helloAck(), payloadLength: 0, now: 0)
        #expect(
            streaming.ended(by: TransportError.writeFailed("Broken pipe"), afterFrames: 1) == [
                .finish(.connectionLost)
            ])
    }

    /// A host that closes without a word never spoke Gliff: not a link to retry.
    @Test func cleanEndBeforeHelloAckIsAConnectFailure() {
        var core = Self.core()
        #expect(
            core.ended(by: nil, afterFrames: 0) == [
                .finish(.connectFailed(.other("The host closed the connection before Gliff started.")))
            ])
    }

    /// Cancelling run() is a disconnect.
    @Test func cancellationIsADisconnect() {
        var core = Self.core()
        #expect(core.ended(by: CancellationError(), afterFrames: 3) == [.finish(.disconnected)])
    }

    /// Upstream re-checks every HelloAck before StreamConfig.
    @Test func repeatedHelloAckIsCheckedAgain() {
        var core = Self.core()
        _ = core.receive(Self.helloAck(), payloadLength: 0, now: 0)
        #expect(core.receive(Self.helloAck(), payloadLength: 0, now: 0) == [])
        let actions = core.receive(Self.helloAck(version: 2), payloadLength: 0, now: 0)
        guard case .finish(.incompatible) = actions.last else {
            Issue.record("expected incompatible, got \(actions)")
            return
        }
    }

    @Test func olderServerVersionNamesTheServer() {
        var core = Self.core()
        #expect(
            core.receive(Self.helloAck(version: 0), payloadLength: 0, now: 0) == [
                .finish(
                    .incompatible(
                        "The server speaks Gliff protocol v0; Glifftop speaks v1. Update gliff-server on the host."
                    ))
            ])
    }

    /// Server text is shown as ssh's is: no control characters, at most 200 characters.
    @Test func serverTextIsMadeDisplayable() {
        var core = Self.core()
        let text = "\u{1b}\u{07}" + String(repeating: "x", count: 300)
        let actions = core.receive(.error(code: 300, message: text, version: nil), payloadLength: 0, now: 0)
        #expect(
            actions == [.finish(.serverError(code: 300, message: String(repeating: "x", count: 200) + "…"))])
    }

    @Test func stopSendsBye() {
        var core = Self.core()
        #expect(core.stop() == [.send(.bye), .finish(.disconnected)])
        #expect(core.stop() == [])
    }

    @Test func endMessages() {
        #expect(SessionEnd.disconnected.message == "Disconnected.")
        #expect(SessionEnd.connectionLost.message == "The connection was lost.")
        #expect(SessionEnd.connectFailed(.hostNotFound).message == ConnectFailure.hostNotFound.message)
        #expect(SessionEnd.remoteNotGliff.message.hasPrefix("The host printed text before Gliff started."))
        #expect(SessionEnd.serverError(code: 300, message: "boom").message.contains("boom"))
        #expect(SessionEnd.serverSetupFailed("no gpu").message.contains("no gpu"))
    }

    /// gliff-server's setup error for an `--output` it can't find (`setup_output`: "no output
    /// NAME"): the monitor chosen isn't connected.
    @Test func aMissingMonitorIsRecognised() {
        let missing = SessionEnd.serverSetupFailed("no output DP-3")
        #expect(missing.isMissingMonitor(.named("DP-3")))
        #expect(!missing.isMissingMonitor(.named("DP-2")))
        #expect(!missing.isMissingMonitor(.focused))
        #expect(!SessionEnd.serverSetupFailed("no gpu").isMissingMonitor(.named("DP-3")))
        #expect(!SessionEnd.connectionLost.isMissingMonitor(.named("DP-3")))
    }

    @Test func onlyTransientEndsMayReconnect() {
        #expect(SessionEnd.connectionLost.mayReconnect)
        #expect(SessionEnd.serverSetupFailed("x").mayReconnect)
        #expect(SessionEnd.connectFailed(.unreachable).mayReconnect)
        // Codes outside 1–255 aren't incompatibility (upstream msg.rs): a retry may work.
        #expect(SessionEnd.serverError(code: 300, message: "x").mayReconnect)
        #expect(!SessionEnd.connectFailed(.permissionDenied).mayReconnect)
        #expect(!SessionEnd.disconnected.mayReconnect)
        #expect(!SessionEnd.incompatible("x").mayReconnect)
    }
}
