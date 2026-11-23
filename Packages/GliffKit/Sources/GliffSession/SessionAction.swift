import GliffProtocol

/// What `SessionCore` asks the session actor to do, in order.
enum SessionAction: Equatable {
    case send(ClientMessage)
    case configureDecoder(StreamConfig)
    /// A StreamConfig that keeps the coded stream (a new view, pace, scale or pipeline).
    case updateDecoder(StreamConfig)
    /// Decode this frame (its payload is the frame's main then aux bytes).
    case decode(VideoFrameHeader)
    /// A cursor shape: validate it with the frame's payload and show it if valid.
    case cursor(CursorShape)
    /// Where the host's pointer is, in capture-buffer pixels.
    case cursorPosition(x: Double, y: Double, visible: Bool)
    case status(SessionStatus)
    /// The server echoed these features: activate them (sorted names).
    case activate(features: [String])
    /// Hand the current unknown message, with its payload, to this feature.
    case deliver(feature: String)
    /// A clipboard message for the bridge (its payload is the frame's).
    case clipboard(ClipboardMessage)
    case finish(SessionEnd)
}
