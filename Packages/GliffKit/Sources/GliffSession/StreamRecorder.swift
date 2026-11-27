import Foundation
import GliffProtocol
import os

/// Records the raw stream to `glifftop-<yyyyMMdd-HHmmss>.gliffrec`: the frames as they came
/// over the wire, starting with the StreamConfig in force and then video frames from the
/// first keyframe, until `duration` has passed since that keyframe. Nothing else (no cursor, clipboard or
/// unknown frames), so the file replays as a stream.
actor StreamRecorder {
    nonisolated let fileURL: URL
    private let duration: Duration
    /// Set when the file opens at the first keyframe.
    private var deadline: ContinuousClock.Instant?
    /// The latest StreamConfig frame, written when recording starts.
    private var config: Frame?
    private var file: FileHandle?
    private var done = false

    private static let log = Logger(subsystem: "io.github.cbyrd01.Glifftop", category: "GliffSession")

    /// `config` is the StreamConfig frame in force, for a recording started mid-stream.
    init(directory: URL, duration: Duration, now: Date, config: Frame? = nil) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        fileURL = directory.appending(path: "glifftop-\(stamp).gliffrec")
        self.duration = duration
        self.config = config
    }

    /// Offers one received frame. Returns false once recording is over; the file is then
    /// closed.
    func offer(frame: Frame, message: ServerMessage) -> Bool {
        guard !done else { return false }
        switch message {
        case .streamConfig:
            config = frame
            if file != nil { write(frame) }
        case .videoFrame(let header):
            if file == nil {
                guard header.isKeyframe, let config else { return true }
                open()
                write(config)
            }
            write(frame)
        default:
            break
        }
        if let deadline, ContinuousClock.now >= deadline { finish() }
        return !done
    }

    /// Stops recording and closes the file.
    func finish() {
        done = true
        try? file?.close()
        file = nil
    }

    private func open() {
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: fileURL)
        else {
            Self.log.error("can't create the recording at \(self.fileURL.path, privacy: .public)")
            done = true
            return
        }
        file = handle
        deadline = .now + duration
        Self.log.info("recording to \(self.fileURL.path, privacy: .public)")
    }

    /// Writes the frame as it came over the wire: header, body, payload.
    private func write(_ frame: Frame) {
        do {
            let header = try FrameHeader(
                bodyLength: UInt32(frame.body.count), payloadLength: UInt32(frame.payload.count))
            try file?.write(contentsOf: header.encoded)
            try file?.write(contentsOf: frame.body)
            try file?.write(contentsOf: frame.payload)
        } catch {
            Self.log.error("recording stopped: \(error.localizedDescription, privacy: .public)")
            finish()
        }
    }
}
