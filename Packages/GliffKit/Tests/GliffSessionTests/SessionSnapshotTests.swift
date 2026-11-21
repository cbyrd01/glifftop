import GliffClipboard
import GliffProtocol
import GliffSession
import GliffVideo
import Testing

/// What the app shows: the session's statuses folded into one value.
@Suite struct SessionSnapshotTests {
    static let stream = StreamInfo(HandshakeTests.config)
    static func stats(_ fps: Double) -> SessionStats {
        SessionStats(
            framesPerSecond: fps, megabitsPerSecond: 8, roundTripMilliseconds: 3, decodeMilliseconds: 2)
    }

    private func fold(_ statuses: [SessionStatus]) -> (SessionSnapshot, [SessionSnapshot.Phase]) {
        var snapshot = SessionSnapshot()
        var phases: [SessionSnapshot.Phase] = []
        for status in statuses {
            snapshot.apply(status)
            phases.append(snapshot.phase)
        }
        return (snapshot, phases)
    }

    @Test func startsIdle() {
        let snapshot = SessionSnapshot()
        #expect(snapshot.phase == .idle)
        #expect(snapshot.stream == nil && snapshot.stats == nil && snapshot.end == nil)
    }

    @Test func followsASessionToItsEnd() {
        let (snapshot, phases) = fold([
            .connecting, .handshaking, .waitingForVideo(HandshakeTests.session, HandshakeTests.output),
            .streaming(Self.stream),
            .stats(Self.stats(30)), .stats(Self.stats(60)), .ended(.connectionLost),
        ])
        #expect(
            phases == [
                .connecting, .handshaking, .waitingForVideo, .streaming, .streaming, .streaming, .ended,
            ])
        #expect(snapshot.stream == Self.stream)
        #expect(snapshot.stats == Self.stats(60))
        #expect(snapshot.end == .connectionLost)
    }

    /// The server's session, from `.waitingForVideo`: whether it is headless (its video then
    /// carries the pointer, so the app shows no cursor of its own while captured).
    @Test func keepsTheServersSession() {
        #expect(SessionSnapshot().session == nil)
        let headless = SessionInfo(headless: true, output: "HEADLESS-1")
        let (snapshot, _) = fold([.handshaking, .waitingForVideo(headless, nil), .streaming(Self.stream)])
        #expect(snapshot.session == headless)
    }

    /// The session's own output (its monitor's size, for a mirror's window).
    @Test func waitingForVideoKeepsTheOutput() {
        #expect(SessionSnapshot().output == nil)
        let (snapshot, _) = fold([
            .handshaking, .waitingForVideo(HandshakeTests.session, HandshakeTests.output),
            .streaming(Self.stream),
        ])
        #expect(snapshot.output == HandshakeTests.output)
    }

    /// A mirror's window: the first view, which the server caps to its encoder and the Hello
    /// caps (upstream `fit_extent`), never larger than the monitor; nil until streaming.
    @Test(arguments: [
        // A 5K monitor on a 4096 encoder: the capped view, not the monitor.
        (OutputInfo(name: "FAKE-1", width: 5120, height: 2880, scaleMilli: 2000), 4096, 2304, 4096, 2304),
        // Nothing capped: the monitor.
        (OutputInfo(name: "FAKE-1", width: 1280, height: 720, scaleMilli: 1000), 1280, 720, 1280, 720),
        // A view past the monitor (no server sends one): the monitor bounds it.
        (OutputInfo(name: "FAKE-1", width: 1280, height: 720, scaleMilli: 1000), 1920, 1080, 1280, 720),
    ])
    func mirrorSizeIsTheFirstViewWithinTheMonitor(
        output: OutputInfo, viewWidth: UInt32, viewHeight: UInt32, width: Int, height: Int
    ) {
        var config = HandshakeTests.config
        (config.viewWidth, config.viewHeight) = (viewWidth, viewHeight)
        let (waiting, _) = fold([.handshaking, .waitingForVideo(HandshakeTests.session, output)])
        #expect(waiting.mirrorSize == nil)
        let (snapshot, _) = fold([
            .handshaking, .waitingForVideo(HandshakeTests.session, output), .streaming(StreamInfo(config)),
        ])
        #expect(snapshot.mirrorSize == PixelSize(width: width, height: height))
    }

    @Test func mirrorSizeWithoutAnOutputIsTheView() {
        let (snapshot, _) = fold([
            .handshaking, .waitingForVideo(HandshakeTests.session, nil), .streaming(Self.stream),
        ])
        #expect(snapshot.mirrorSize == PixelSize(width: 1280, height: 720))
    }

    /// Stats can arrive before the first `.streaming` reaches the app; they are kept, and the
    /// phase doesn't move.
    @Test func statsBeforeStreamingAreKept() {
        let (snapshot, phases) = fold([.connecting, .stats(Self.stats(30))])
        #expect(phases == [.connecting, .connecting])
        #expect(snapshot.stats == Self.stats(30))
    }

    @Test func anInterruptionComesAndGoes() {
        let (interrupted, _) = fold([.streaming(Self.stream), .interrupted(true)])
        #expect(interrupted.isInterrupted)
        #expect(interrupted.phase == .streaming)
        let (resumed, _) = fold([.streaming(Self.stream), .interrupted(true), .interrupted(false)])
        #expect(!resumed.isInterrupted)
        // An ended session isn't interrupted: it's over.
        let (ended, _) = fold([.streaming(Self.stream), .interrupted(true), .ended(.connectionLost)])
        #expect(!ended.isInterrupted)
    }

    @Test func nothingAfterTheEnd() {
        let (snapshot, _) = fold([
            .connecting, .ended(.disconnected), .streaming(Self.stream), .stats(Self.stats(30)),
            .ended(.connectionLost),
        ])
        #expect(snapshot.phase == .ended)
        #expect(snapshot.end == .disconnected)
        #expect(snapshot.stream == nil && snapshot.stats == nil)
    }

    /// The stream's scale, as the server sent it (live checks read a virtual screen's).
    @Test func streamInfoKeepsTheScale() {
        var config = HandshakeTests.config
        config.scaleMilli = 1500
        #expect(StreamInfo(config).scaleMilli == 1500)
    }

    /// A stream the server's ladder halved still reports its screen's 2× (upstream
    /// `stream_config`: the output's scale times the stream's downscale).
    @Test func theScreenScaleUndoesTheStreamsDownscale() {
        var config = HandshakeTests.config
        (config.width, config.viewWidth, config.scaleMilli) = (800, 1600, 1000)
        #expect(StreamInfo(config).screenScale == 2)
    }

    @Test func clipboardActivityIsKept() {
        let activity = ClipboardActivity(label: "text", done: 1, state: .running)
        let offer = RemoteClipboardOffer(serial: 1, mimeTypes: ["text/plain"])
        let (snapshot, _) = fold([
            .clipboardActivity(activity), .stats(Self.stats(30)), .clipboardOffer(offer),
        ])
        #expect(snapshot.clipboard == activity)
    }

    @Test func aReadStillRunningFailsWhenTheSessionEnds() {
        let activity = ClipboardActivity(label: "text", done: 1, state: .running)
        let (snapshot, _) = fold([.clipboardActivity(activity), .ended(.connectionLost)])
        #expect(snapshot.clipboard?.state == .failed(TransferError.connectionEnded.message))
    }
}
