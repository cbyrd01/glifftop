public import GliffSFTP
public import GliffTransport
import os

/// One sftp conversation over any byte stream: INIT, then requests by id, each answered in any
/// order.
///
/// - One reader task cuts the stream into replies and hands each to its request's waiter.
/// - A caller cancelled while waiting marks its id abandoned: its reply, when it comes, is read
///   and dropped, and a HANDLE in it is closed. A reply to an id never issued or already
///   answered, or of the wrong shape for its request (`ExpectedReply`), breaks the session.
/// - sftp-server answers in order, so any reply is progress: while a written request is
///   outstanding, abandoned or not, the next reply is due within the longest limit among them
///   (60 s; fsync 60 s plus 1 s per 16 MiB written), counted from the last reply or from the
///   write that found none outstanding. With none in time, the session ends.
/// - A cancelled call throws `.cancelled`, even when its reply has come: what it asked of the
///   host may or may not have been done.
/// - A cancelled task sends no request but CLOSE; other cleanup after a cancel runs in a task of
///   its own.
/// - A broken rule, the stream's end, or `close()` fails every waiter, and every later call.
/// - An ending closes the stream, never the connection under it: a file server held up by a
///   slow disk or a hung mount looks like a dead link, and ssh's keepalive finds a real one.
public actor SFTPSession {
    /// What VERSION offered.
    public nonisolated let extensions: SFTPExtensions

    /// The usual time limit for a reply.
    public static let replyLimit: Duration = .seconds(60)

    private let connection: any ByteConnection
    private let clock: any Clock<Duration>
    private var nextID: UInt32 = 1
    private var pending: [UInt32: Pending] = [:]
    /// The timer for the next reply, while a written request is outstanding.
    private var watchdog: Task<Void, Never>?
    private var ending: FilesError?
    private var reader: Task<Void, Never>?

    private struct Pending {
        let expected: ExpectedReply
        let limit: Duration
        var written = false
        var state: State

        enum State {
            /// Sent; its caller hasn't begun to wait.
            case sent
            case waiting(CheckedContinuation<Result<SFTPReply, FilesError>, Never>)
            /// The outcome came before its caller began to wait.
            case settled(Result<SFTPReply, FilesError>)
            /// Its caller went away; the reply, when it comes, is dropped.
            case abandoned
        }

        /// Its outcome has come, though its caller hasn't taken it.
        var isSettled: Bool {
            if case .settled = state { true } else { false }
        }
    }

    private init(connection: any ByteConnection, extensions: SFTPExtensions, clock: any Clock<Duration>) {
        (self.connection, self.extensions, self.clock) = (connection, extensions, clock)
    }

    /// Sends INIT alone and waits for VERSION, within `replyLimit`. A failed start closes the
    /// stream; a cancelled one throws `.cancelled`.
    public static func start(
        over connection: any ByteConnection, clock: any Clock<Duration> = ContinuousClock()
    ) async throws(FilesError) -> SFTPSession {
        guard !Task.isCancelled else {
            await connection.close()
            throw .cancelled
        }
        // A failed write is left to the stream's end, which says why, or to the time limit.
        try? await connection.write(SFTPRequest.initialize.encoded(id: 0))
        var opening = await Self.opening(connection, clock: clock)
        if Task.isCancelled { opening = .failure(.cancelled) }
        switch opening {
        case .success(let opened):
            let session = SFTPSession(connection: connection, extensions: opened.extensions, clock: clock)
            await session.startReading(after: opened.framer)
            return session
        case .failure(let error):
            await connection.close()
            throw error
        }
    }

    /// Ends the session: every waiter and every later call fails as `.ended`. The owner calls
    /// it: the reader holds the session until the stream ends.
    public func close() async { await end(.ended) }

    // MARK: Requests

    /// Sends `request` and waits for its reply, within `limit`. A cancelled task sends nothing.
    func send(_ request: SFTPRequest, limit: Duration = replyLimit) async throws(FilesError) -> SFTPReply {
        if let ending { throw ending }
        if Task.isCancelled { throw .cancelled }
        let id = nextID
        nextID = nextID == .max ? 1 : nextID + 1
        pending[id] = Pending(expected: ExpectedReply(request), limit: limit, state: .sent)
        // A failed write is left to the stream's end, which says why (a lost link, the server's
        // exit), or to the timer.
        try? await connection.write(request.encoded(id: id))
        pending[id]?.written = true
        if watchdog == nil { rewatch() }
        let result = await wait(for: id)
        // A cancelled caller drops whatever came, as an abandoned id's reply is dropped.
        if Task.isCancelled {
            closeUnused(result)
            throw .cancelled
        }
        return try result.get()
    }

    /// A reply that breaks the protocol: the session ends as broken; the session's end.
    func unexpected() async -> FilesError {
        return await end(.protocolBroken)
    }

    private func wait(for id: UInt32) async -> Result<SFTPReply, FilesError> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                switch pending[id]?.state {
                case .settled(let result):
                    pending[id] = nil
                    continuation.resume(returning: result)
                // Not reached: an entry leaves only once waited for. Here so no continuation
                // is ever left unresumed.
                case nil:
                    continuation.resume(returning: .failure(ending ?? .ended))
                default:
                    pending[id]?.state = .waiting(continuation)
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    /// The caller of `id` went away: its reply, if it hasn't come, is dropped when it does, and
    /// its time limit still holds.
    private func abandon(_ id: UInt32) {
        switch pending[id]?.state {
        case .waiting(let continuation):
            continuation.resume(returning: .failure(.cancelled))
            pending[id]?.state = .abandoned
        default: break
        }
    }

    /// Closes the handle in an outcome nobody will use.
    private func closeUnused(_ result: Result<SFTPReply, FilesError>) {
        if case .success(.handle(_, let handle)) = result { Task { try? await self.close(handle: handle) } }
    }

    /// Settles `id` with `result`: resumes its caller, or keeps the result for a caller still
    /// sending.
    private func settle(_ id: UInt32, with result: Result<SFTPReply, FilesError>) {
        switch pending[id]?.state {
        case .waiting(let continuation):
            pending[id] = nil
            continuation.resume(returning: result)
        case .abandoned:
            pending[id] = nil
            closeUnused(result)
        case .sent:
            pending[id]?.state = .settled(result)
        case .settled, nil:
            break
        }
    }

    /// Starts the timer afresh with the longest limit among the written requests still
    /// outstanding, or stops it when there are none.
    private func rewatch() {
        watchdog?.cancel()
        watchdog = nil
        guard ending == nil else { return }
        let limits = pending.values.lazy.filter { $0.written && !$0.isSettled }.map(\.limit)
        guard let limit = limits.max() else { return }
        watchdog = Self.watching(for: limit, on: clock, in: self)
    }

    /// The timer, off the actor: starting and cancelling it queue no work on the session.
    private static func watching(
        for limit: Duration, on clock: any Clock<Duration>, in session: SFTPSession
    ) -> Task<Void, Never> {
        Task {
            do { try await clock.sleep(for: limit) } catch { return }
            await session.timedOut()
        }
    }

    /// Runs in the timer's task: one cancelled after its sleep ended is stale.
    private func timedOut() async {
        guard !Task.isCancelled else { return }
        await end(.timedOut)
    }

    // MARK: Replies

    private func startReading(after framer: SFTPFramer) {
        reader = Self.reading(connection, after: framer, into: self)
    }

    /// The reader, off the actor: it frames and decodes each chunk, then hands the replies over.
    private static func reading(
        _ connection: any ByteConnection, after framer: SFTPFramer, into session: SFTPSession
    ) -> Task<Void, Never> {
        Task {
            var framer = framer
            let outcome: FilesError
            do {
                for try await chunk in connection.incoming {
                    let replies = try framer.feed(chunk).map { packet throws(SFTPError) in
                        try SFTPReply.decode(packet)
                    }
                    // A chunk that completes no packet needs no hop to the actor.
                    if replies.isEmpty { continue }
                    guard await session.deliver(replies) else { return }
                }
                // A reply cut short by the end is the end, not a broken rule.
                outcome = .ended
            } catch {
                outcome = FilesError(reading: error)
            }
            await session.end(outcome)
        }
    }

    /// Hands each reply to its waiter; false once the session has ended.
    private func deliver(_ replies: [SFTPReply]) async -> Bool {
        guard ending == nil else { return false }
        guard replies.allSatisfy(accept) else {
            await end(.protocolBroken)
            return false
        }
        rewatch()
        return true
    }

    /// Settles the reply's request; false when the reply breaks a rule.
    private func accept(_ reply: SFTPReply) -> Bool {
        guard let id = reply.id, let waiter = pending[id], !waiter.isSettled, waiter.expected.allows(reply)
        else {
            return false
        }
        settle(id, with: .success(reply))
        return true
    }

    /// Fails every waiter with `error`, and every later call; the session's end, the first one
    /// wins. The stream is closed.
    @discardableResult private func end(_ error: FilesError) async -> FilesError {
        if let ending { return ending }
        ending = error
        for id in pending.keys { settle(id, with: .failure(error)) }
        FilesLog.logger.debug("sftp session ended: \(String(describing: error), privacy: .public)")
        // Before the tasks are cancelled: either may be the one running this.
        await connection.close()
        watchdog?.cancel()
        reader?.cancel()
        return error
    }
}
