import GliffProtocol
import GliffVideo
import os

/// The bookkeeping while video flows: frames sent to decode, the keyframe latch, RTT pings
/// and the stats window.
struct VideoState {
    struct Pending {
        var frameID: UInt64
        var isKeyframe: Bool
    }

    /// Frames handed to the decoder and not yet acked, in arrival order: a list, not a
    /// dictionary, so a repeated id still gets one ack per VideoFrame.
    var pending: [Pending] = []
    /// A keyframe was requested and none has decoded since.
    var awaitingKeyframe = false
    var lastPing: UInt64?
    /// The client's own Pings not yet answered, oldest first (at most `maxOutstandingPings`).
    var outstandingPings: [UInt64] = []
    var roundTrip: Double?
    /// nil until the first frame or tick while streaming.
    var window: StatsWindow?
}

/// What was decoded since `start`, for one stats report.
struct StatsWindow {
    var start: UInt64
    var frames = 0
    var bytes: UInt64 = 0
    var decodeMilliseconds = 0.0
}

extension SessionCore {
    /// How often the client measures the round trip (upstream pings every 2 s).
    static let pingInterval: UInt64 = 2000
    /// How often stats are reported.
    static let statsInterval: UInt64 = 1000
    /// A server that never answers can't grow the list without bound.
    static let maxOutstandingPings = 4

    private static let log = Logger(subsystem: "me.cbyrd.Glifftop", category: "GliffSession")

    /// A StreamConfig once HelloAck is in, or a new one while streaming.
    mutating func streamConfig(_ config: StreamConfig) -> [SessionAction] {
        if let reason = StreamRules.validate(config) { return finish(.protocolError(reason)) }
        let rebuild = stream.map { StreamRules.needsNewDecoder(from: $0, to: config) } ?? true
        enterStreaming(config)
        let status = SessionAction.status(.streaming(StreamInfo(config)))
        return [rebuild ? .configureDecoder(config) : .updateDecoder(config), status]
    }

    /// A message while streaming.
    mutating func streaming(_ message: ServerMessage, payloadLength: Int, now: UInt64) -> [SessionAction] {
        switch message {
        case .streamConfig(let config):
            return streamConfig(config)
        case .videoFrame(let frame):
            video.pending.append(.init(frameID: frame.frameID, isKeyframe: frame.isKeyframe))
            // The window opens with the first frame, so a burst before the first tick counts.
            if video.window == nil { video.window = StatsWindow(start: now) }
            video.window?.bytes += UInt64(frame.dataLength) + UInt64(frame.auxLength)
            return [.decode(frame)]
        case .pong(let t, _):
            if let index = video.outstandingPings.firstIndex(of: t) {
                video.outstandingPings.remove(at: index)
                // `now` is the wall clock: a step backwards gives no sample.
                if now >= t { video.roundTrip = Double(now - t) }
            }
            return []
        case .cursorShape(let shape):
            return [.cursor(shape)]
        // CursorPos is ignored (upstream's client too).
        default:
            return []
        }
    }

    /// The decoder finished with a frame (GPU work done): ack it, exactly once.
    mutating func decoded(frameID: UInt64, outcome: DecodeOutcome, decodeMilliseconds: Double, now: UInt64)
        -> [SessionAction]
    {
        guard !isFinished else { return [] }
        guard let index = video.pending.firstIndex(where: { $0.frameID == frameID }) else {
            Self.log.fault("decoded frame \(frameID) that was never sent to decode")
            return []
        }
        let frame = video.pending.remove(at: index)
        var actions: [SessionAction] = [.send(.frameAck(frameID: frameID, decodedAtMilliseconds: now))]
        switch outcome {
        case .failed:
            // Ask once per run of failures; a keyframe that fails too asks again.
            if !video.awaitingKeyframe || frame.isKeyframe {
                video.awaitingKeyframe = true
                actions.append(.send(.requestKeyframe))
            }
        case .picture, .noPicture:
            if frame.isKeyframe { video.awaitingKeyframe = false }
        }
        // As upstream: fps and decode time count pictures only.
        if outcome == .picture {
            video.window?.frames += 1
            video.window?.decodeMilliseconds += decodeMilliseconds
        }
        return actions
    }

    /// The clock: an RTT Ping every `pingInterval`, stats every `statsInterval`.
    mutating func tick(now: UInt64) -> [SessionAction] {
        guard state == .streaming else { return [] }
        return [ping(now: now), stats(now: now)].compactMap { $0 } + resizeDue(now: now)
    }

    /// A Ping now, whenever the last went (the wake probe), its `t` being `now`; nil unless
    /// streaming.
    mutating func pingNow(now: UInt64) -> SessionAction? {
        guard state == .streaming else { return nil }
        video.lastPing = nil
        return ping(now: now)
    }

    /// The window's latest size and scale; sent by `resizeDue` once it settles.
    mutating func setViewTarget(_ target: ViewTarget, now: UInt64) {
        resize.set(target, now: now)
    }

    /// A Resize, when one is due and video is streaming.
    mutating func resizeDue(now: UInt64) -> [SessionAction] {
        guard state == .streaming, let stream else { return [] }
        let view = ResizeRules.View(
            width: stream.viewWidth, height: stream.viewHeight, scale: Float(StreamInfo(stream).screenScale))
        let headless = session?.headless ?? false
        return resize.due(now: now, headless: headless, view: view, pipeline: stream.pipeline).map {
            [.send($0)]
        } ?? []
    }

    private mutating func ping(now: UInt64) -> SessionAction? {
        // A clock step backwards (now < lastPing) pings again rather than waiting it out.
        guard video.lastPing.map({ now < $0 || now - $0 >= Self.pingInterval }) ?? true else { return nil }
        video.lastPing = now
        video.outstandingPings.append(now)
        if video.outstandingPings.count > Self.maxOutstandingPings { video.outstandingPings.removeFirst() }
        return .send(.ping(t: now))
    }

    private mutating func stats(now: UInt64) -> SessionAction? {
        // No window yet, or the clock stepped back: start one now.
        guard let window = video.window, now >= window.start else {
            video.window = StatsWindow(start: now)
            return nil
        }
        let elapsed = now - window.start
        guard elapsed >= Self.statsInterval else { return nil }
        video.window = StatsWindow(start: now)
        let seconds = Double(elapsed) / 1000
        let frames = Double(window.frames)
        return .status(
            .stats(
                SessionStats(
                    framesPerSecond: frames / seconds,
                    megabitsPerSecond: Double(window.bytes) * 8 / seconds / 1_000_000,
                    roundTripMilliseconds: video.roundTrip,
                    decodeMilliseconds: frames == 0 ? 0 : window.decodeMilliseconds / frames)))
    }
}
