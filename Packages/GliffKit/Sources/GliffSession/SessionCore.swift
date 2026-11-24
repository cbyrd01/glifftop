import GliffProtocol
import GliffTransport

/// The session's rules, with no I/O, clock or concurrency: messages in, actions out.
/// Ported from upstream's client (`net.rs`); the streaming rules are in
/// `SessionCore+Streaming.swift`.
struct SessionCore {
    enum State: Equatable {
        case notStarted, awaitingHelloAck, awaitingStreamConfig, streaming, finished
    }

    let configuration: SessionConfiguration
    /// Each feature offered in Hello, with the server variants it claims.
    let features: [String: Set<Int64>]
    private(set) var state = State.notStarted
    /// Offered features the server echoed, sorted.
    private(set) var activeFeatures: [String] = []
    /// The StreamConfig in force once streaming.
    private(set) var stream: StreamConfig?
    /// Frames, pings and stats while streaming (`SessionCore+Streaming.swift`).
    var video = VideoState()
    /// The server's session, from HelloAck.
    private(set) var session: SessionInfo?
    /// When the window's size goes to the server (`ResizeRules`).
    var resize = ResizeRules()
    /// Whether a virtual screen's first picture waits for its size (`PictureHold`).
    var hold = PictureHold()

    init(configuration: SessionConfiguration, features: [String: Set<Int64>]) {
        self.configuration = configuration
        self.features = features
    }

    var isFinished: Bool { state == .finished }

    mutating func start() -> [SessionAction] {
        guard state == .notStarted else { return [] }
        state = .awaitingHelloAck
        let caps = ClientCaps(
            codecs: StreamRules.codecs, maxWidth: min(configuration.maxWidth, StreamRules.maxSide),
            maxHeight: min(configuration.maxHeight, StreamRules.maxSide), chroma: StreamRules.chroma,
            features: features.keys.sorted())
        return [
            .status(.handshaking),
            .send(.hello(version: GliffProtocol.version, keymap: configuration.keymap, caps: caps)),
        ]
    }

    /// One server message. `payloadLength` is what its frame carried; `now` is wall-clock ms.
    mutating func receive(_ message: ServerMessage, payloadLength: Int, now: UInt64) -> [SessionAction] {
        guard !isFinished else { return [] }
        do {
            try message.checkPayload(carried: payloadLength)
        } catch {
            return finish(.protocolError("\(error)"))
        }
        switch message {
        case .ping(let t):
            return [.send(.pong(t: t))]
        case .unknown(let variant):
            return route(variant)
        case .error(let code, let raw, _):
            let text = SSHErrorClassifier.displayable(raw)
            if ErrorCode.isIncompatible(code) { return finish(.incompatible(text)) }
            if code == ErrorCode.setup { return finish(.serverSetupFailed(text)) }
            return finish(.serverError(code: code, message: text))
        case .helloAck(let version, let session, let outputs, let echoed):
            return helloAck(version: version, session: session, outputs: outputs, echoed: echoed)
        case .clipboard(let message):
            // Once the handshake is done, at any point of the stream; before it, nothing.
            let ready = state == .awaitingStreamConfig || state == .streaming
            return ready ? [.clipboard(message)] : []
        default:
            break
        }
        switch state {
        case .streaming:
            return streaming(message, payloadLength: payloadLength, now: now)
        case .awaitingStreamConfig:
            guard case .streamConfig(let config) = message else {
                return finish(.protocolError("\(Self.name(of: message)) before StreamConfig"))
            }
            return streamConfig(config, now: now)
        default:
            return finish(.protocolError("\(Self.name(of: message)) before HelloAck"))
        }
    }

    /// The user disconnects: say Bye once.
    mutating func stop() -> [SessionAction] {
        guard !isFinished else { return [] }
        let bye: [SessionAction] = state == .notStarted ? [] : [.send(.bye)]
        return bye + finish(.disconnected)
    }

    /// The incoming stream ended: cleanly (`error == nil`) or with a transport or parse
    /// error. `afterFrames` is how many frames had been parsed: a parse error on the very
    /// first one means stdout carried something other than Gliff (a login banner).
    mutating func ended(by error: (any Error)?, afterFrames: Int) -> [SessionAction] {
        guard !isFinished else { return [] }
        // Before HelloAck, the connection never got going: a failure to connect, not a link
        // to retry.
        let connecting = state == .awaitingHelloAck
        switch error {
        case nil where connecting:
            return finish(.connectFailed(.other("The host closed the connection before Gliff started.")))
        case nil:
            return finish(.connectionLost)
        case is CancellationError:
            return finish(.disconnected)
        case let error as TransportError:
            switch error {
            case .exited(_, let failure):
                return finish(connecting ? .connectFailed(failure) : .connectionLost)
            case .launchFailed(let reason):
                return finish(.connectFailed(.other(reason)))
            // The writer's EPIPE can beat the reader's classified exit (a changed host key):
            // while connecting, wait for that exit instead.
            case .writeFailed where connecting:
                return []
            case .writeFailed:
                return finish(.connectionLost)
            case .cancelled:
                return finish(.disconnected)
            }
        case let error as ProtocolError:
            return finish(afterFrames == 0 ? .remoteNotGliff : .protocolError("\(error)"))
        default:
            return finish(.connectionLost)
        }
    }

    /// The one way into (and on within) the streaming state.
    mutating func enterStreaming(_ config: StreamConfig) {
        state = .streaming
        stream = config
    }

    mutating func finish(_ end: SessionEnd) -> [SessionAction] {
        state = .finished
        return [.finish(end)]
    }

    private mutating func helloAck(
        version: UInt16, session: SessionInfo, outputs: [OutputInfo], echoed: [String]
    ) -> [SessionAction] {
        // Upstream checks every HelloAck before StreamConfig, and ignores them after.
        guard state == .awaitingHelloAck || state == .awaitingStreamConfig else { return [] }
        guard version == GliffProtocol.version else {
            let update =
                version > GliffProtocol.version ? "Update Glifftop." : "Update gliff-server on the host."
            return finish(
                .incompatible(
                    "The server speaks Gliff protocol v\(version); Glifftop speaks v\(GliffProtocol.version). "
                        + update))
        }
        guard state == .awaitingHelloAck else { return [] }
        state = .awaitingStreamConfig
        self.session = session
        activeFeatures = Set(echoed).intersection(features.keys).sorted()
        let activate: [SessionAction] = activeFeatures.isEmpty ? [] : [.activate(features: activeFeatures)]
        // It bounds a mirror's window (`SessionSnapshot.mirrorSize`): an impossible size is no
        // output at all.
        let output = outputs.first { $0.name == session.output }.flatMap(StreamRules.monitor)
        return [.status(.waitingForVideo(session, output))] + activate
    }

    /// An unknown server variant goes to the active feature that claims it, else is skipped.
    private func route(_ variant: Int64) -> [SessionAction] {
        guard let feature = activeFeatures.first(where: { features[$0]?.contains(variant) == true }) else {
            return []
        }
        return [.deliver(feature: feature)]
    }

    static func name(of message: ServerMessage) -> String {
        switch message {
        case .helloAck: "HelloAck"
        case .streamConfig: "StreamConfig"
        case .videoFrame: "VideoFrame"
        case .cursorShape: "CursorShape"
        case .cursorPosition: "CursorPos"
        case .clipboard(let message): message.kind.rawValue
        case .pong: "Pong"
        case .error: "Error"
        case .ping: "Ping"
        case .unknown(let variant): "message \(variant)"
        }
    }

    static func name(of message: ClientMessage) -> String {
        switch message {
        case .hello: "Hello"
        case .resize: "Resize"
        case .key: "Key"
        case .pointerMotion: "PointerMotion"
        case .pointerButton: "PointerButton"
        case .pointerAxis: "PointerAxis"
        case .frameAck: "FrameAck"
        case .requestKeyframe: "RequestKeyframe"
        case .clipboard(let message): message.kind.rawValue
        case .ping: "Ping"
        case .bye: "Bye"
        case .keymap: "Keymap"
        case .pong: "Pong"
        }
    }

}
