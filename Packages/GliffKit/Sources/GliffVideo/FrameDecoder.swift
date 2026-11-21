public import GliffProtocol

/// What became of one video frame.
public enum DecodeOutcome: Equatable, Sendable {
    /// A picture is ready for display.
    case picture
    /// Decoded, but nothing to show yet (or no display: `NullFrameDecoder`).
    case noPicture
    case failed(String)
}

/// Turns the stream's frames into pictures. The session awaits each `decode` before it acks
/// the frame: that wait is the back-pressure the server paces itself on.
public protocol FrameDecoder: Sendable {
    /// Called for the first StreamConfig and for every one that changes the coded stream.
    func configure(_ config: StreamConfig) async throws
    /// Called for a StreamConfig that keeps the coded stream: the decoder keeps its sessions
    /// and takes what else changed (the remote view its pictures fill).
    func update(_ config: StreamConfig) async
    /// `main` and `aux` are slices of one payload: `aux` starts at index `main.count`, not 0.
    /// Index them through `startIndex` (or `withUnsafeBytes`), never from 0.
    func decode(_ frame: VideoFrameHeader, main: ArraySlice<UInt8>, aux: ArraySlice<UInt8>) async
        -> DecodeOutcome
}

extension FrameDecoder {
    /// A decoder with nothing to take from a kept stream ignores it.
    public func update(_ config: StreamConfig) async {}
}

/// Decodes nothing: every frame is `.noPicture`. For session tests that need no pictures.
public struct NullFrameDecoder: FrameDecoder {
    public init() {}

    public func configure(_ config: StreamConfig) async throws {}

    public func decode(_ frame: VideoFrameHeader, main: ArraySlice<UInt8>, aux: ArraySlice<UInt8>) async
        -> DecodeOutcome
    {
        .noPicture
    }
}
