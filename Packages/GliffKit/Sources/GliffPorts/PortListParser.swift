/// Reads the watcher's output (`PortWatchCommand`), untrusted, a chunk at a time.
///
/// - A frame runs from `B <nonce> ...` to `E <nonce>`, this run's nonce only; text outside a
///   frame is skipped, and what comes before the first is counted.
/// - A frame over 64 KiB (its `B` line and body) or 600 lines (its `B` and `E` among them) is
///   dropped and counted; 128 KiB with no frame start or end is an overflow, which ends the watcher
///   (nothing more is read).
/// - Numbers come only from `P` lines; an `N` line only names a socket a `P` line gave.
public struct PortListParser: Sendable {
    public enum Output: Equatable, Sendable {
        case frame(PortFrame)
        /// The host has no `/proc/net/tcp`: the watcher ended.
        case unavailable
        /// Too much output without a frame end.
        case overflow
    }

    static let frameBytes = 64 * 1024
    static let frameLines = 600
    static let unframedBytes = 128 * 1024

    private let nonce: String
    private var pending: [UInt8] = []
    /// Bytes since the last frame end, the pending line's among them.
    private var sinceFrameEnd = 0
    private var state = State.outside
    private var seenFrame = false
    private var overflowed = false

    /// Frames dropped for a cap, or for no end before the next frame.
    public private(set) var droppedFrames = 0
    /// Bytes before the first frame (a shell startup file that prints).
    public private(set) var bytesBeforeFirstFrame = 0

    /// Where the parser is: between frames, reading one (its header's words, its lines and
    /// bytes so far), or skipping one over a cap.
    private enum State {
        case outside
        case reading(header: [Substring], lines: [String], bytes: Int)
        case dropping
    }

    public init(nonce: String) { self.nonce = nonce }

    public mutating func feed(_ bytes: [UInt8]) -> [Output] {
        guard !overflowed else { return [] }
        var outputs: [Output] = []
        for byte in bytes {
            sinceFrameEnd += 1
            if byte == UInt8(ascii: "\n") {
                let (line, size) = (String(decoding: pending, as: UTF8.self), pending.count + 1)
                pending.removeAll(keepingCapacity: true)
                if let output = take(line, size: size) { outputs.append(output) }
            } else {
                pending.append(byte)
            }
            if sinceFrameEnd > Self.unframedBytes {
                overflowed = true
                pending = []
                return outputs + [.overflow]
            }
        }
        return outputs
    }

    private mutating func take(_ line: String, size: Int) -> Output? {
        let words = line.split(whereSeparator: \.isWhitespace)
        if words.count >= 3, words[0] == "B", words[1] == nonce {
            seenFrame = true
            // A frame still open had no end: it is dropped.
            if case .outside = state {} else { droppedFrames += 1 }
            (state, sinceFrameEnd) = (.reading(header: words, lines: [], bytes: size), size)
            return nil
        }
        let ends = words.count == 2 && words[0] == "E" && words[1] == nonce
        switch state {
        case .outside:
            if !seenFrame { bytesBeforeFirstFrame += size }
            return nil
        case .dropping:
            if ends {
                droppedFrames += 1
                (state, sinceFrameEnd) = (.outside, 0)
            }
            return nil
        case .reading(let header, var lines, let bytes):
            if ends {
                (state, sinceFrameEnd) = (.outside, 0)
                return PortFrameReader.output(header: header, lines: lines)
            }
            // Dropped before the append, so a frame's lines aren't copied as they grow. The
            // line cap counts this line, B and E.
            state = .dropping
            guard bytes + size <= Self.frameBytes, lines.count + 3 <= Self.frameLines else { return nil }
            lines.append(line)
            state = .reading(header: header, lines: lines, bytes: bytes + size)
            return nil
        }
    }
}
