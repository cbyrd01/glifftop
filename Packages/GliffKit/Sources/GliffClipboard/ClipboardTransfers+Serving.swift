public import GliffProtocol
import os

extension ClipboardTransfers {
    /// Streams `source` to the peer as the answer to its request `id`: chunks of at most
    /// `ClipboardLimits.chunk`, at most `ClipboardLimits.window` unacked, then an empty final
    /// chunk. A source that fails, or an ack window that stalls for `idleTimeout`, aborts it. A
    /// repeated id ends the first serve. `onEnd` is told how it ended: nil once the final chunk
    /// is sent, else why not.
    public func serve(
        id: UInt32, from source: any ChunkSource, progress: TransferProgress?,
        onEnd: (@Sendable (TransferError?) -> Void)? = nil
    ) {
        guard !closed else {
            onEnd?(.connectionEnded)
            return
        }
        if outgoing[id] != nil {
            Self.log.warning("clipboard request id reused while serving")
            stopServing(id, .invalid)
        }
        nextToken += 1
        let token = nextToken
        outgoing[id] = Outgoing(token: token, onEnd: onEnd)
        outgoing[id]?.task = Task {
            await self.serveLoop(id, token: token, source: source, progress: progress)
        }
    }

    /// Aborts everything being served (an offer was withdrawn, or the person cancelled), each
    /// serve ending for `reason`.
    public func abortServing(_ reason: TransferError = .cancelled) async {
        let ids = Array(outgoing.keys)
        for id in ids { stopServing(id, reason) }
        for id in ids { await emit(.abort(id: id)) }
    }

    func acked(id: UInt32, received: UInt64) async {
        guard outgoing[id] != nil else { return }
        do {
            try outgoing[id]?.window.onAck(received)
        } catch {
            Self.log.warning("bad clipboard ack")
            await abortOutgoing(id, .invalid)
            return
        }
        if outgoing[id]?.window.maySend == true { resumeCredit(id, true) }
    }

    /// Ends serve `id` for `reason`, without a word to the peer.
    func stopServing(_ id: UInt32, _ reason: TransferError) {
        guard let entry = outgoing.removeValue(forKey: id) else { return }
        entry.task?.cancel()
        entry.creditTimer?.cancel()
        entry.credit?.waiter.resume(returning: false)
        entry.onEnd?(reason)
    }

    /// Ends serve `id` for `reason` and tells the peer.
    func abortOutgoing(_ id: UInt32, _ reason: TransferError) async {
        guard outgoing[id] != nil else { return }
        stopServing(id, reason)
        await emit(.abort(id: id))
    }

    private func isCurrent(_ id: UInt32, _ token: Int) -> Bool { outgoing[id]?.token == token }

    private func serveLoop(_ id: UInt32, token: Int, source: any ChunkSource, progress: TransferProgress?)
        async
    {
        // A source may hand over more than a chunk; the rest goes in the next ones.
        var pending: ArraySlice<UInt8> = []
        while true {
            guard await waitForCredit(id, token) else { return }
            if pending.isEmpty {
                switch await withDeadline(idleTimeout, { try await source.read(upTo: ClipboardLimits.chunk) })
                {
                case .done(let bytes): pending = bytes[...]
                case .cancelled: return
                case .failed:
                    Self.log.warning("clipboard source failed")
                    if isCurrent(id, token) { await abortOutgoing(id, .failed) }
                    return
                case .timedOut:
                    Self.log.warning("clipboard source stalled")
                    if isCurrent(id, token) { await abortOutgoing(id, .timedOut) }
                    return
                }
            }
            let bytes = Array(pending.prefix(ClipboardLimits.chunk))
            pending = pending.dropFirst(bytes.count)
            guard isCurrent(id, token), let offset = outgoing[id]?.window.offset else { return }
            let done = bytes.isEmpty
            outgoing[id]?.window.onSent(bytes.count)
            progress?.add(UInt64(bytes.count))
            let onEnd = done ? outgoing.removeValue(forKey: id)?.onEnd : nil
            await emit(.data(id: id, offset: offset, dataLength: UInt32(bytes.count), done: done), bytes)
            if done {
                onEnd?(nil)
                return
            }
        }
    }

    /// Waits until serve `id` may send; false if it ended or the window stalled (then aborted).
    private func waitForCredit(_ id: UInt32, _ token: Int) async -> Bool {
        while let entry = outgoing[id], entry.token == token, !entry.window.maySend {
            nextToken += 1
            let wait = nextToken
            let granted = await withCheckedContinuation { credit in
                outgoing[id]?.credit = (credit, wait)
                outgoing[id]?.creditTimer = Task { [idleTimeout] in
                    do { try await Task.sleep(for: idleTimeout) } catch { return }
                    await self.creditTimedOut(id, wait: wait)
                }
            }
            guard granted else { return false }
        }
        return isCurrent(id, token)
    }

    private func resumeCredit(_ id: UInt32, _ granted: Bool) {
        guard let credit = outgoing[id]?.credit else { return }
        outgoing[id]?.credit = nil
        outgoing[id]?.creditTimer?.cancel()
        credit.waiter.resume(returning: granted)
    }

    /// Serve `id`'s credit wait `wait` ran out; a later wait, or a newer serve, is left alone.
    private func creditTimedOut(_ id: UInt32, wait: Int) async {
        guard outgoing[id]?.credit?.wait == wait else { return }
        Self.log.warning("clipboard serve stalled")
        await abortOutgoing(id, .timedOut)
    }

    /// Sends an offer of ours (not a transfer, but the same wire); nothing once closed.
    public func sendOffer(serial: UInt32, mimeTypes: [String], files: [ClipboardFile]) async {
        await emit(.offer(serial: serial, mimeTypes: mimeTypes, files: files))
    }

    struct Outgoing {
        var window = SendWindow()
        let token: Int
        var task: Task<Void, Never>?
        var credit: (waiter: CheckedContinuation<Bool, Never>, wait: Int)?
        var creditTimer: Task<Void, Never>?
        let onEnd: (@Sendable (TransferError?) -> Void)?

        init(token: Int, onEnd: (@Sendable (TransferError?) -> Void)?) {
            (self.token, self.onEnd) = (token, onEnd)
        }
    }
}
