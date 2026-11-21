public import GliffClipboard
public import GliffProtocol
public import GliffVideo

/// Everything the app shows about one session, folded from its `status` stream.
public struct SessionSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, connecting, handshaking, waitingForVideo, streaming, ended
    }

    public var phase = Phase.idle
    /// The server's session (whether it is headless, its output), once the handshake is done.
    public var session: SessionInfo?
    /// The session's own output (its monitor's size and scale), when HelloAck listed it.
    public var output: OutputInfo?
    /// The size a mirror's window is fitted to, read at the first stream: its view,
    /// which the server capped to its encoder and the Hello caps (upstream `fit_extent`), and
    /// never larger than the monitor. A later view (the server's answer to the window) mustn't
    /// size the window, so the app reads this once. Nil until streaming.
    public var mirrorSize: PixelSize? {
        guard let stream else { return nil }
        let (width, height) = (Int(stream.viewWidth), Int(stream.viewHeight))
        guard let output else { return PixelSize(width: width, height: height) }
        return PixelSize(width: min(width, Int(output.width)), height: min(height, Int(output.height)))
    }
    /// The stream in force once streaming.
    public var stream: StreamInfo?
    /// The latest stats.
    public var stats: SessionStats?
    /// Why the session ended, once it has.
    public var end: SessionEnd?
    /// The server has gone quiet while streaming: the picture may be stale.
    public var isInterrupted = false
    /// The host's latest read of our clipboard, kept until the next.
    public var clipboard: ClipboardActivity?

    public init() {}

    /// Folds in one status. Nothing changes once the session has ended.
    public mutating func apply(_ status: SessionStatus) {
        guard phase != .ended else { return }
        switch status {
        case .connecting: phase = .connecting
        case .handshaking: phase = .handshaking
        case .waitingForVideo(let info, let output):
            phase = .waitingForVideo
            session = info
            self.output = output
        case .streaming(let info):
            phase = .streaming
            stream = info
        case .stats(let stats): self.stats = stats
        case .interrupted(let on): isInterrupted = on
        case .clipboardActivity(let activity): clipboard = activity
        case .clipboardOffer: break
        case .ended(let end):
            phase = .ended
            self.end = end
            isInterrupted = false
            // The bridge closed with the session: a read still shown as running ended with it.
            if clipboard?.state == .running {
                clipboard?.state = .failed(TransferError.connectionEnded.message)
            }
        }
    }
}
