public import GliffProtocol
import os

/// What the bridge tells the app.
public enum ClipboardBridgeEvent: Equatable, Sendable {
    case remoteOffer(RemoteClipboardOffer)
    case activity(ClipboardActivity)
}

/// The client's clipboard, both ways, over one session's transfers. Mac → remote: our offers,
/// their serials and the rules a request must pass. Remote → Mac: the remote's
/// offer, and fetching its types into memory. Files aren't shared.
public actor ClipboardBridge {
    static let log = Logger(subsystem: "me.cbyrd.Glifftop", category: "GliffClipboard")

    let transfers: ClipboardTransfers
    let source: any LocalClipboardSource
    private let activityDelay: Duration
    private let activityEvery: Duration
    public nonisolated let events: AsyncStream<ClipboardBridgeEvent>
    let continuation: AsyncStream<ClipboardBridgeEvent>.Continuation
    var closed = false

    // Mac → remote.
    private var nextSerial: UInt32 = 1
    private var current: Current?
    /// The running activity of each offer the host is reading, by serial.
    private var runs: [UInt32: ActivityRun] = [:]
    private var nextRun = 0
    /// Bumped by every offer, revoke and cancel: a serve prepared before one is not started.
    private var generation = 0
    /// The app's reads of requested items still under way, by a key of their own.
    private var preparing: [Int: Task<Void, Never>] = [:]
    private var nextPreparing = 0
    /// The last offer or revoke on its way to the wire: each waits for the one before.
    private var announcing: Task<Void, Never>?

    // Remote → Mac (ClipboardBridge+Remote).
    /// The remote's latest offer; nil until its first (cleared only when the bridge closes).
    var remote: RemoteClipboardOffer?

    public init(transfers: ClipboardTransfers, source: any LocalClipboardSource) {
        self.init(
            transfers: transfers, source: source, activityDelay: .seconds(1),
            activityEvery: .milliseconds(250))
    }

    init(
        transfers: ClipboardTransfers, source: any LocalClipboardSource, activityDelay: Duration,
        activityEvery: Duration
    ) {
        (self.transfers, self.source) = (transfers, source)
        (self.activityDelay, self.activityEvery) = (activityDelay, activityEvery)
        (events, continuation) = AsyncStream.makeStream()
    }

    // MARK: Mac → remote

    /// Offers the Mac's clipboard; whatever the last offer was serving is aborted. A password
    /// manager's copy carries KDE's marker, so the host's clipboard history doesn't keep it.
    public func offer(_ offer: LocalClipboardOffer) async {
        guard !closed else { return }
        let serial = withdraw()
        // The marker is ours to add, once, and only beside a type: it alone is no copy.
        var offer = offer
        offer.mimeTypes.removeAll { $0 == ClipboardMimes.passwordHint }
        offer.isPassword = offer.isPassword && !offer.mimeTypes.isEmpty
        current = Current(serial: serial, offer: offer)
        let mimes = offer.mimeTypes + (offer.isPassword ? [ClipboardMimes.passwordHint] : [])
        await announce { [transfers] in
            await transfers.abortServing(.replaced)
            await transfers.sendOffer(serial: serial, mimeTypes: mimes, files: [])
        }
    }

    /// Withdraws our offer: requests against it are refused and what it serves is aborted. An
    /// empty offer follows only if asked: it would replace whatever the host's clipboard holds.
    public func revoke(sendEmpty: Bool) async {
        guard !closed else { return }
        let serial = withdraw()
        await announce { [transfers] in
            await transfers.abortServing(.replaced)
            if sendEmpty { await transfers.sendOffer(serial: serial, mimeTypes: [], files: []) }
        }
    }

    /// The person cancelled the host's read of our offer.
    public func cancelServing() async {
        stopPreparing()
        await transfers.abortServing(.cancelled)
    }

    /// Withdraws the current offer at once, before any suspension, and takes a fresh serial.
    private func withdraw() -> UInt32 {
        current = nil
        stopPreparing()
        return takeSerial()
    }

    /// Stops the app's reads under way: none of them will be served.
    private func stopPreparing() {
        generation += 1
        for task in preparing.values { task.cancel() }
    }

    /// Runs `step` once every earlier offer or revoke has gone, so they reach the wire in serial
    /// order.
    private func announce(_ step: @escaping @Sendable () async -> Void) async {
        let previous = announcing
        let task = Task {
            await previous?.value
            await step()
        }
        announcing = task
        await task.value
    }

    /// A fresh serial: never one the peer may still hold.
    private func takeSerial() -> UInt32 {
        defer { nextSerial &+= 1 }
        return nextSerial
    }

    // MARK: From the wire

    /// One clipboard message from the server.
    public func receive(_ message: ClipboardMessage, payload: [UInt8]) async {
        guard !closed else { return }
        switch await transfers.receive(message, payload: payload) {
        case .offer(let serial, let mimeTypes, let files)?:
            remoteOffered(serial: serial, mimeTypes: mimeTypes, files: files)
        case .request(let id, let serial, let item)?:
            await request(id: id, serial: serial, item: item)
        case nil:
            break
        }
    }

    private func request(id: UInt32, serial: UInt32, item: ClipboardItem) async {
        guard let current, current.serial == serial else {
            Self.log.info("clipboard request for a withdrawn offer refused")
            return await transfers.refuse(id: id)
        }
        guard case .mime(let mime) = item else {
            Self.log.info("clipboard file request refused: files aren't shared")
            return await transfers.refuse(id: id)
        }
        if current.offer.isPassword, mime == ClipboardMimes.passwordHint {
            // The marker has no data: one empty final chunk, so the host's read succeeds quietly.
            return await transfers.serve(id: id, from: MemorySource([]), progress: nil)
        }
        guard let resolved = ClipboardMimes.resolve(mime, in: current.offer.mimeTypes) else {
            Self.log.info("clipboard request for a type not offered refused")
            return await transfers.refuse(id: id)
        }
        Self.log.info("clipboard read being served")
        startServing(id, mime: resolved, of: current)
    }

    /// Asks the app for the item in a task of its own, so the reader never waits on it; a read
    /// that takes longer than the idle timeout is refused.
    private func startServing(_ id: UInt32, mime: String, of current: Current) {
        let run = joinRun(mime, of: current)
        let (serial, token, began) = (current.serial, current.offer.token, generation)
        nextPreparing += 1
        let key = nextPreparing
        preparing[key] = Task { [source, transfers] in
            let outcome = await withDeadline(transfers.idleTimeout) {
                () -> Result<any ChunkSource, TransferError> in
                do throws(TransferError) {
                    return .success(try await source.source(for: mime, token: token))
                } catch {
                    return .failure(error)
                }
            }
            let made: Result<any ChunkSource, TransferError> =
                switch outcome {
                case .done(let made): made
                case .timedOut: .failure(.timedOut)
                case .cancelled: .failure(.cancelled)
                case .failed: .failure(.failed)
                }
            await serve(id, made, serial: serial, began: began, run: run)
            preparing[key] = nil
        }
    }

    /// Why a serve prepared at `began` for `serial` must not run, if it mustn't.
    private func stopped(_ serial: UInt32, since began: Int) -> TransferError? {
        if current?.serial != serial { return .replaced }
        return generation == began ? nil : .cancelled
    }

    private func serve(
        _ id: UInt32, _ made: Result<any ChunkSource, TransferError>, serial: UInt32, began: Int, run: UInt32
    ) async {
        if let reason = stopped(serial, since: began) {
            await transfers.refuse(id: id)
            return serveEnded(run, reason)
        }
        switch made {
        case .success(let source):
            let progress = runs[run]?.progress
            await transfers.serve(id: id, from: source, progress: progress) { reason in
                Task { await self.serveEnded(run, reason) }
            }
            // Withdrawn or cancelled while the serve was being handed over: its abort missed it.
            if let reason = stopped(serial, since: began) { await transfers.abortOutgoing(id, reason) }
        case .failure(let error):
            Self.log.info(
                "clipboard item not served: \(String(describing: error), privacy: .public)")
            await transfers.refuse(id: id)
            serveEnded(run, error)
        }
    }

    // MARK: Activity

    /// Joins the activity of `current`'s serves, starting one if none is running.
    private func joinRun(_ mime: String, of current: Current) -> UInt32 {
        let key = current.serial
        if runs[key] != nil {
            runs[key]?.active += 1
            return key
        }
        nextRun += 1
        runs[key] = ActivityRun(
            id: nextRun, label: ClipboardActivity.label(mime: mime), progress: TransferProgress())
        runs[key]?.reporter = Task { [activityDelay, activityEvery, id = nextRun] in
            do {
                try await Task.sleep(for: activityDelay)
                while true {
                    report(key, run: id)
                    try await Task.sleep(for: activityEvery)
                }
            } catch {}
        }
        return key
    }

    /// Reports run `id` of `key`'s activity, if it is still the one running: a wake that
    /// outlived its run never reports a newer read of the same offer.
    private func report(_ key: UInt32, run id: Int) {
        guard let run = runs[key], run.id == id else { return }
        runs[key]?.reported = true
        continuation.yield(.activity(run.activity))
    }

    private func serveEnded(_ key: UInt32, _ reason: TransferError?) {
        guard var run = runs[key] else { return }
        run.active -= 1
        if run.failure == nil { run.failure = reason }
        runs[key] = run
        if run.active == 0 { endRun(key) }
    }

    /// Ends the activity, reporting how it ended if it was reported at all.
    private func endRun(_ key: UInt32) {
        guard let run = runs.removeValue(forKey: key) else { return }
        run.reporter?.cancel()
        guard run.reported else { return }
        var activity = run.activity
        activity.state = ClipboardActivity.state(after: run.failure)
        continuation.yield(.activity(activity))
    }

    // MARK: The end

    /// The session ended: every transfer ends, and no more events follow.
    public func close() async {
        closed = true
        current = nil
        remote = nil
        stopPreparing()
        await transfers.close()
        for run in runs.values { run.reporter?.cancel() }
        runs = [:]
        continuation.finish()
    }

    private struct Current {
        let serial: UInt32
        let offer: LocalClipboardOffer
    }
}
