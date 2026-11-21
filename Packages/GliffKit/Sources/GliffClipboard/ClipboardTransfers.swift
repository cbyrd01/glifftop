public import GliffProtocol
import os

/// Which end an engine runs at: each picks transfer ids of its own parity (the client's odd), so
/// transfers in opposite directions never share an id.
enum TransferSide: Sendable {
    case client
    case server

    var parity: UInt32 { self == .client ? 1 : 0 }
}

/// A clipboard message the owner must act on.
public enum TransferEvent: Equatable, Sendable {
    case offer(serial: UInt32, mimeTypes: [String], files: [ClipboardFile])
    case request(id: UInt32, serial: UInt32, item: ClipboardItem)
}

/// The clipboard's transfers, both ways (a port of upstream's `Transfers`): fetches the peer's
/// items in chunks, acking each, and serves ours within the send window. `receive` never waits on
/// a sink or a source, so the session's reader is never held up by a slow disk.
public actor ClipboardTransfers {
    public typealias Send = @Sendable (ClipboardMessage, [UInt8]) async -> Void

    static let log = Logger(subsystem: "me.cbyrd.Glifftop", category: "GliffClipboard")

    private let send: Send
    let side: TransferSide
    let idleTimeout: Duration
    private var nextID: UInt32
    private(set) var closed = false
    private var incoming: [UInt32: Incoming] = [:]
    var outgoing: [UInt32: Outgoing] = [:]
    /// Tells apart waits and serves that reuse an id.
    var nextToken = 0

    /// A client engine; every message it sends goes through `send`, a `Data`'s chunk as payload.
    public init(send: @escaping Send) {
        self.init(side: .client, send: send)
    }

    init(side: TransferSide, idleTimeout: Duration = ClipboardLimits.idleTimeout, send: @escaping Send) {
        (self.side, self.idleTimeout, self.send) = (side, idleTimeout, send)
        nextID = side == .client ? 1 : 2
    }

    // MARK: From the peer

    /// Handles one message from the peer: an offer or a request is the owner's to act on.
    public func receive(_ message: ClipboardMessage, payload: [UInt8]) async -> TransferEvent? {
        switch message {
        case .offer(let serial, let mimeTypes, let files):
            return .offer(serial: serial, mimeTypes: mimeTypes, files: files)
        case .request(let id, let serial, let item):
            guard id % 2 != side.parity else {
                Self.log.warning("clipboard request with our own id parity refused")
                await emit(.abort(id: id))
                return nil
            }
            return .request(id: id, serial: serial, item: item)
        case .data(let id, let offset, let length, let done):
            await received(id: id, offset: offset, length: length, done: done, payload: payload)
        case .ack(let id, let received):
            await acked(id: id, received: received)
        case .abort(let id):
            stopServing(id, .aborted)
            fail(id, .aborted)
        }
        return nil
    }

    private func received(id: UInt32, offset: UInt64, length: UInt32, done: Bool, payload: [UInt8]) async {
        // A finished or failed transfer's chunks are dropped: the peer has our Abort.
        guard var entry = incoming[id], !entry.failed else { return }
        var failure: TransferError?
        if payload.count != Int(length) {
            failure = .invalid
        } else {
            do {
                try entry.assembler.accept(offset: offset, length: length, done: done)
            } catch .overCap {
                failure = .tooLarge
            } catch {
                failure = .invalid
            }
        }
        if failure == nil, entry.queue.count >= ClipboardLimits.window + 2 { failure = .invalid }
        incoming[id] = entry
        if let failure {
            Self.log.warning("clipboard chunk rejected (\(payload.count) bytes)")
            fail(id, failure)
            await emit(.abort(id: id))
        } else {
            deliver(id, .data(payload, done: done))
        }
    }

    // MARK: Fetching

    /// Asks the peer for `item` of offer `serial` and writes it to `sink`; the byte count once
    /// the sink has finished. Over `cap`, cancelled, or `idleTimeout` without a chunk, the
    /// transfer is aborted.
    public func fetch(
        _ item: ClipboardItem, serial: UInt32, into sink: any ChunkSink, cap: UInt64?,
        progress: TransferProgress?
    ) async throws(TransferError) -> UInt64 {
        guard !closed else { throw .connectionEnded }
        let id = nextID
        nextID &+= 2
        if nextID == 0 { nextID = 2 }
        incoming[id] = Incoming(assembler: Assembler(cap: cap))
        defer { incoming[id] = nil }
        await emit(.request(id: id, serial: serial, item: item))
        var received: UInt64 = 0
        while true {
            switch await nextChunk(id) {
            case .fail(let error):
                if error == .cancelled || error == .timedOut { await emit(.abort(id: id)) }
                throw error
            case .data(let bytes, let done):
                try await bounded(id) { try await sink.write(bytes) }
                received += UInt64(bytes.count)
                progress?.add(UInt64(bytes.count))
                if done {
                    try await bounded(id) { try await sink.finish() }
                    return received
                }
                if Task.isCancelled {
                    await emit(.abort(id: id))
                    throw .cancelled
                }
                // A transfer that failed meanwhile gets no ack: its failure is next in the queue.
                if incoming[id]?.failed == false { await emit(.ack(id: id, received: received)) }
            }
        }
    }

    /// The next chunk of fetch `id`, waiting for it up to `idleTimeout`.
    private func nextChunk(_ id: UInt32) async -> Chunk {
        guard let entry = incoming[id] else { return .fail(.connectionEnded) }
        if Task.isCancelled { return .fail(.cancelled) }
        if let chunk = entry.queue.first {
            incoming[id]?.queue.removeFirst()
            return chunk
        }
        nextToken += 1
        let token = nextToken
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                incoming[id]?.waiter = (waiter, token)
                incoming[id]?.timer = Task { [idleTimeout] in
                    try? await Task.sleep(for: idleTimeout)
                    self.wake(id, token: token, with: .fail(.timedOut))
                }
            }
        } onCancel: {
            Task { await self.wake(id, token: token, with: .fail(.cancelled)) }
        }
    }

    /// Resumes fetch `id`'s wait `token` with `chunk`, if it is still waiting.
    private func wake(_ id: UInt32, token: Int, with chunk: Chunk) {
        guard let (waiter, waiting) = incoming[id]?.waiter, waiting == token else { return }
        incoming[id]?.waiter = nil
        incoming[id]?.timer?.cancel()
        waiter.resume(returning: chunk)
    }

    private func deliver(_ id: UInt32, _ chunk: Chunk) {
        if let (_, token) = incoming[id]?.waiter {
            wake(id, token: token, with: chunk)
        } else {
            incoming[id]?.queue.append(chunk)
        }
    }

    /// Ends fetch `id` with `error`, ahead of anything queued; later chunks are dropped.
    private func fail(_ id: UInt32, _ error: TransferError) {
        guard incoming[id]?.failed == false else { return }
        incoming[id]?.failed = true
        incoming[id]?.queue = []
        deliver(id, .fail(error))
    }

    // MARK: Both ways

    /// Declines the peer's request `id`.
    public func refuse(id: UInt32) async {
        await emit(.abort(id: id))
    }

    /// The connection ended: every fetch fails with `connectionEnded`, every serve stops, and
    /// nothing more is sent.
    public func close() {
        closed = true
        for id in incoming.keys { fail(id, .connectionEnded) }
        for id in outgoing.keys { stopServing(id, .connectionEnded) }
    }

    func emit(_ message: ClipboardMessage, _ payload: [UInt8] = []) async {
        guard !closed else { return }
        await send(message, payload)
    }

    /// Runs fetch `id`'s sink `call` within `idleTimeout`; if it fails, stalls or is cancelled,
    /// the transfer is aborted.
    private func bounded(_ id: UInt32, _ call: @escaping @Sendable () async throws -> Void)
        async throws(TransferError)
    {
        let error: TransferError
        switch await withDeadline(idleTimeout, call) {
        case .done: return
        case .failed: error = .failed
        case .timedOut: error = .timedOut
        case .cancelled: error = .cancelled
        }
        if incoming[id]?.failed == false {
            fail(id, error)
            await emit(.abort(id: id))
        }
        throw error
    }

    enum Chunk: Sendable {
        case data([UInt8], done: Bool)
        case fail(TransferError)
    }

    private struct Incoming {
        var assembler: Assembler
        var queue: [Chunk] = []
        var waiter: (CheckedContinuation<Chunk, Never>, token: Int)?
        var timer: Task<Void, Never>?
        var failed = false
    }
}
