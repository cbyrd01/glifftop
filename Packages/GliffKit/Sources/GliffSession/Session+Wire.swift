import GliffProtocol
import os

/// Frames onto the writer, and what the protocol observer hears of the frames read.
extension Session {
    func enqueue(_ message: ClientMessage) {
        send(body: message.encoded, type: SessionCore.name(of: message))
    }

    /// `type` names the message for the observer (a feature's frames, by the feature).
    func send(body: [UInt8], payload: [UInt8] = [], type: String) {
        guard let writer else { return }
        do {
            writer.send(try Frame.encode(body: body, payload: payload), type: type)
        } catch {
            Self.log.error("not sent, over the frame limits: \(error)")
        }
    }

    /// A frame read and decoded: its type and its whole size, header included.
    func observed(_ frame: Frame, _ message: ServerMessage) {
        guard let observer else { return }
        let bytes = FrameHeader.size + frame.body.count + frame.payload.count
        observer.observed(
            ProtocolEvent(direction: .received, type: SessionCore.name(of: message), bytes: bytes, time: .now)
        )
    }
}
