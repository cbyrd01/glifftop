public import GliffClipboard
public import GliffProtocol
public import GliffTransport

/// What the app tells a session about this Mac.
public struct SessionConfiguration: Equatable, Sendable {
    /// The largest display, in pixels. Hello clamps each side to the decoder's 4096.
    public var maxWidth: UInt32
    public var maxHeight: UInt32
    /// XKB keymap text; empty makes the server default to `us`. The app leaves it empty and
    /// sends the layout as a Keymap: a Hello keymap the server can't compile fails its setup.
    public var keymap: String

    public init(maxWidth: UInt32, maxHeight: UInt32, keymap: String = "") {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.keymap = keymap
    }
}

/// The video stream as the last StreamConfig set it.
public struct StreamInfo: Equatable, Sendable {
    public var chroma: ChromaMode
    public var pipeline: VideoPipeline?
    public var width, height, viewWidth, viewHeight, fpsCap: UInt32
    /// The output's scale times any downscale of the stream, in thousandths (upstream
    /// `stream_config`).
    public var scaleMilli: UInt32

    public init(_ config: StreamConfig) {
        chroma = config.chroma
        pipeline = config.pipeline
        width = config.width
        height = config.height
        viewWidth = config.viewWidth
        viewHeight = config.viewHeight
        fpsCap = config.fpsCap
        scaleMilli = config.scaleMilli
    }

    /// `scaleMilli` with the stream's downscale from the view undone: the output's scale times
    /// the view's fit to the output. A virtual screen's own scale while its view is the whole
    /// output (within the encoder's limit); less for a mirror fitted below its monitor.
    public var screenScale: Double {
        Double(scaleMilli) / 1000 * Double(viewWidth) / Double(max(width, 1))
    }
}

/// Measured once a second while streaming.
public struct SessionStats: Equatable, Sendable {
    public var framesPerSecond: Double
    /// Main plus aux payload.
    public var megabitsPerSecond: Double
    /// nil until the first Pong for one of the client's own Pings.
    public var roundTripMilliseconds: Double?
    public var decodeMilliseconds: Double

    public init(
        framesPerSecond: Double, megabitsPerSecond: Double, roundTripMilliseconds: Double?,
        decodeMilliseconds: Double
    ) {
        self.framesPerSecond = framesPerSecond
        self.megabitsPerSecond = megabitsPerSecond
        self.roundTripMilliseconds = roundTripMilliseconds
        self.decodeMilliseconds = decodeMilliseconds
    }
}

public enum SessionStatus: Equatable, Sendable {
    case connecting
    case handshaking
    /// The handshake is done: the server's session, and its own output from HelloAck (nil when
    /// HelloAck didn't list it).
    case waitingForVideo(SessionInfo, OutputInfo?)
    case streaming(StreamInfo)
    case stats(SessionStats)
    /// The link went quiet while streaming (true: `Liveness`), or the server was heard from
    /// again (false).
    case interrupted(Bool)
    /// The remote's clipboard changed (fetched only when pasted on the Mac).
    case clipboardOffer(RemoteClipboardOffer)
    /// The host reading our clipboard, once it has taken a while.
    case clipboardActivity(ClipboardActivity)
    case ended(SessionEnd)
}

/// Why a session ended.
public enum SessionEnd: Error, Equatable, Sendable {
    /// The user disconnected.
    case disconnected
    case connectionLost
    case connectFailed(ConnectFailure)
    /// The host wrote something other than Gliff frames to stdout (a login banner).
    case remoteNotGliff
    case incompatible(String)
    /// Error 256: the server couldn't start the session; a reconnect may succeed.
    case serverSetupFailed(String)
    case serverError(code: UInt16, message: String)
    case protocolError(String)
    case decoderFailed(String)

    /// What the app shows.
    public var message: String {
        switch self {
        case .disconnected: "Disconnected."
        case .connectionLost: "The connection was lost."
        case .connectFailed(let failure): failure.message
        case .remoteNotGliff:
            "The host printed text before Gliff started. A login banner or shell startup output on "
                + "stdout breaks the connection; move it to stderr or make it interactive-only."
        case .incompatible(let reason): reason
        case .serverSetupFailed(let message): "The server couldn't start the session: \(message)"
        case .serverError(let code, let message): "The server reported error \(code): \(message)"
        case .protocolError(let detail): "The server sent something Glifftop doesn't understand: \(detail)"
        case .decoderFailed(let detail): "The video couldn't be decoded: \(detail)"
        }
    }

    /// Whether the session ended because `screen`, a monitor by name, isn't connected: the
    /// server's setup error for an `--output` it can't find ("no output NAME").
    public func isMissingMonitor(_ screen: ScreenChoice) -> Bool {
        guard case .serverSetupFailed(let message) = self, case .named(let name) = screen else {
            return false
        }
        return message == "no output \(name)"
    }

    /// Whether trying again could work.
    public var mayReconnect: Bool {
        switch self {
        // serverError is only ever a code outside 1–255, which upstream says a retry may fix.
        case .connectionLost, .serverSetupFailed, .serverError, .connectFailed(.unreachable),
            .connectFailed(.channelRefused), .connectFailed(.sharedConnectionLost):
            true
        default: false
        }
    }
}

/// What a session needs to carry the clipboard: how the app reads the Mac's clipboard when the
/// host asks.
public struct ClipboardSetup: Sendable {
    public var source: any LocalClipboardSource

    public init(source: any LocalClipboardSource) {
        self.source = source
    }
}
