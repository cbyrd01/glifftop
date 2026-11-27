public import GliffClipboard
import GliffProtocol
import Synchronization
import os

/// What the app asks of the session's clipboard, queued in order with its input: offers and
/// revokes keep their order, and wait for the writer.
enum ClipboardCommand: Equatable, Sendable {
    case offer(LocalClipboardOffer)
    case revoke(sendEmpty: Bool)
}

/// The bridge's way to the server: each message goes to the writer as it is sent, a chunk of
/// data in the bulk lane, behind input and acks.
final class ClipboardWire: Sendable {
    private let writer = Mutex<SessionWriter?>(nil)
    private static let log = Logger(subsystem: "io.github.cbyrd01.Glifftop", category: "GliffSession")

    func attach(_ writer: SessionWriter) {
        self.writer.withLock { $0 = writer }
    }

    func send(_ message: ClipboardMessage, payload: [UInt8]) {
        guard let writer = writer.withLock({ $0 }) else { return }
        do {
            let frame = try Frame.encode(body: ClientMessage.clipboard(message).encoded, payload: payload)
            let type = message.kind.rawValue
            if case .data = message {
                writer.sendBulk(frame, type: type)
            } else {
                writer.send(frame, type: type)
            }
        } catch {
            Self.log.error("clipboard message not sent, over the frame limits")
        }
    }
}

extension Session {
    /// Offers the Mac's clipboard to the host, from any thread, in its place among the input.
    /// Offers and revokes go only this way, never to `clipboard` directly.
    public nonisolated func offerClipboard(_ offer: LocalClipboardOffer) {
        guard clipboard != nil else { return }
        inputs.append(.clipboard(.offer(offer)))
    }

    /// Withdraws our offer, from any thread, in its place among the input; an empty offer
    /// follows only if asked.
    public nonisolated func revokeClipboard(sendEmpty: Bool) {
        guard clipboard != nil else { return }
        inputs.append(.clipboard(.revoke(sendEmpty: sendEmpty)))
    }

    /// The bridge for `setup`, sending through `wire`.
    static func makeClipboard(_ setup: ClipboardSetup?, wire: ClipboardWire) -> ClipboardBridge? {
        guard let setup else { return nil }
        let transfers = ClipboardTransfers { message, payload in wire.send(message, payload: payload) }
        return ClipboardBridge(transfers: transfers, source: setup.source)
    }

    /// Once the writer exists: the bridge's messages go out, and its events become statuses.
    func startClipboard() {
        guard let clipboard, let writer else { return }
        clipboardWire.attach(writer)
        clipboardEvents = Task { [weak self] in
            for await event in clipboard.events { await self?.report(event) }
        }
    }

    /// A clipboard message from the server.
    func receiveClipboard(_ message: ClipboardMessage, payload: [UInt8]) async {
        await clipboard?.receive(message, payload: payload)
    }

    /// The bridge ends (every transfer) before the connection closes.
    func closeClipboard() async {
        await clipboard?.close()
        clipboardEvents?.cancel()
    }

    /// Carries out a command while what was queued after it waits, so commands reach the wire
    /// in the order they were made.
    func carryOut(_ command: ClipboardCommand) async {
        if let clipboard, !core.isFinished {
            switch command {
            case .offer(let offer): await clipboard.offer(offer)
            case .revoke(let sendEmpty): await clipboard.revoke(sendEmpty: sendEmpty)
            }
        }
        carryingOut = false
        deliverInput()
    }

    private func report(_ event: ClipboardBridgeEvent) {
        switch event {
        case .remoteOffer(let offer): yield(.clipboardOffer(offer))
        case .activity(let activity): yield(.clipboardActivity(activity))
        }
    }
}
