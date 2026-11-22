import GliffProtocol
import Synchronization

@testable import GliffClipboard

/// The app's side of a Mac offer: `bytes` for any type; counts its calls.
final class FakeLocalSource: LocalClipboardSource {
    private let calls = Mutex(0)
    private let bytes: [UInt8]
    private let error: TransferError?
    /// When set, `source(for:)` itself stalls until released, ignoring cancellation.
    let stall: Stall?

    init(bytes: [UInt8] = [], error: TransferError? = nil, stalls: Bool = false) {
        (self.bytes, self.error) = (bytes, error)
        stall = stalls ? Stall() : nil
    }

    var callCount: Int { calls.withLock { $0 } }

    func source(for mime: String, token: Int) async throws(TransferError) -> any ChunkSource {
        calls.withLock { $0 += 1 }
        await stall?.wait()
        if let error { throw error }
        return MemorySource(bytes)
    }
}

/// A bridge on a client engine whose messages go to a `Wire`.
func recordedBridge(
    _ source: FakeLocalSource = FakeLocalSource(), idleTimeout: Duration = ClipboardLimits.idleTimeout,
    clock: ManualClock = ManualClock()
) -> (ClipboardBridge, Wire) {
    let (engine, wire) = recordedClient(idleTimeout: idleTimeout)
    let bridge = ClipboardBridge(
        transfers: engine, source: source, clock: clock, activityDelay: .milliseconds(100),
        activityEvery: .milliseconds(50)
    )
    return (bridge, wire)
}

extension Wire {
    /// The serial of the last offer sent.
    var lastOfferSerial: UInt32? {
        messages.reversed().lazy.compactMap { message -> UInt32? in
            if case .offer(let serial, _, _) = message { serial } else { nil }
        }.first
    }
}

/// A bridge facing a server engine that offers and serves each mime from `mimes`, refusing
/// anything else.
final class RemotePeer: Sendable {
    let server: ClipboardTransfers
    let bridge: ClipboardBridge
    private let requested = Requests()

    var requests: [ClipboardItem] { requested.items.withLock { $0 } }

    init(mimes: [String: [UInt8]] = [:]) {
        let peers = Mutex<(server: ClipboardTransfers?, bridge: ClipboardBridge?)>((nil, nil))
        let requested = self.requested
        let client = ClipboardTransfers(side: .client) { message, payload in
            guard let server = peers.withLock({ $0.server }),
                case .request(let id, _, let item)? = await server.receive(message, payload: payload)
            else { return }
            requested.items.withLock { $0.append(item) }
            switch item {
            case .mime(let mime) where mimes[mime] != nil:
                await server.serve(id: id, from: MemorySource(mimes[mime]!), progress: nil)
            default:
                await server.refuse(id: id)
            }
        }
        server = ClipboardTransfers(side: .server) { message, payload in
            guard let bridge = peers.withLock({ $0.bridge }) else { return }
            await bridge.receive(message, payload: payload)
        }
        bridge = ClipboardBridge(
            transfers: client, source: FakeLocalSource(), clock: ManualClock(), activityDelay: .seconds(1),
            activityEvery: .milliseconds(250))
        peers.withLock { $0 = (server, bridge) }
    }

    func offer(serial: UInt32, mimeTypes: [String] = [], files: [ClipboardFile] = []) async {
        await server.sendOffer(serial: serial, mimeTypes: mimeTypes, files: files)
    }
}

/// The items a `RemotePeer`'s server was asked for, in order.
final class Requests: Sendable {
    let items = Mutex<[ClipboardItem]>([])
}
