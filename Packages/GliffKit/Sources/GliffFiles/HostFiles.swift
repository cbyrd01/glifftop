import Foundation
public import GliffTransport

/// One who uses a host's sftp channel: the Files window while it is open, or a queued or
/// running batch.
public struct FilesUser: Hashable, Sendable {
    let id: Int
}

/// One host's files: its one sftp channel, which serves browsing and transfers, and its queue of
/// batches (`HostFiles+Queue`).
///
/// - The channel opens at the first user's first request and closes when the last user leaves.
/// - A session's opening reads the host's folders once (`HostFoldersCommand`) and, unless a
///   try is running, removes every temporary the ledger holds for the host by its exact name:
///   outside a running try, each is a leftover.
public actor HostFiles {
    /// The host as the person typed it, for sentences.
    public nonisolated let host: String
    public nonisolated let ledger: TemporaryLedger
    /// Every batch's requests in flight: narrower while a session window to the host streams.
    nonisolated let pipeline = Pipeline()
    let channels: FilesChannels
    let activity: any TransferActivity

    /// Each user's asker, which answers a sign-in the channel needs on its behalf.
    var users: [Int: Asker] = [:]
    var nextUser = 0
    var session: SFTPSession?
    /// The opening under way, by a number of its own; one nobody waits for is cancelled and
    /// forgotten.
    var opening: (id: Int, task: Task<Void, Never>)?
    var nextOpening = 0
    /// The callers waiting for the opening, by a number of their own.
    var waiters: [Int: CheckedContinuation<Result<Opened, FilesError>, Never>] = [:]
    var nextWaiter = 0
    /// The host's folders, read as the first session opened.
    public private(set) var folders: HostFolders?

    var queue: [QueuedBatch] = []
    var running: (id: TransferBatch.ID, task: Task<Void, Never>)?
    var activityToken: (any NSObjectProtocol)?

    /// An asker, kept in a dictionary whose missing key means "no user".
    struct Asker {
        let asker: (any SignInAsker)?
    }

    struct Opened {
        let session: SFTPSession
        let folders: HostFolders?
    }

    public init(
        host: String, channels: FilesChannels, ledger: TemporaryLedger, activity: any TransferActivity
    ) {
        (self.host, self.channels, self.ledger, self.activity) = (host, channels, ledger, activity)
    }

    /// Joins the users; `asker` answers a sign-in the channel needs on this user's behalf.
    public func join(asker: (any SignInAsker)?) -> FilesUser {
        nextUser += 1
        users[nextUser] = Asker(asker: asker)
        return FilesUser(id: nextUser)
    }

    /// Leaves; the last user out closes the channel.
    public func leave(_ user: FilesUser) async {
        users[user.id] = nil
        guard users.isEmpty, let session else { return }
        self.session = nil
        await session.close()
    }

    /// The open session, or a new one once the last has ended. Callers waiting together share
    /// one opening; a cancelled caller stops waiting at once, and the last to go cancels it.
    public func session(for user: FilesUser) async throws(FilesError) -> SFTPSession {
        guard users[user.id] != nil else { throw .cancelled }
        // Another caller may open a session while this one looks at the last.
        while let session {
            if await !session.isEnded { return session }
            if self.session === session { break }
        }
        if opening == nil { startOpening() }
        nextWaiter += 1
        let id = nextWaiter
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.assumeIsolated { $0.waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.stopWaiting(id) }
        }
        return try result.get().session
    }

    private func stopWaiting(_ id: Int) {
        // A waiter the opening already answered left nothing behind.
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: .failure(.cancelled))
        guard waiters.isEmpty, let abandoned = opening else { return }
        abandoned.task.cancel()
        opening = nil
    }

    /// Keeps the session the opening made, unless no user is left for it, and answers everyone
    /// waiting. An abandoned opening's session is closed: nobody waits for it.
    private func finishOpening(_ id: Int, _ result: Result<Opened, FilesError>) async {
        guard opening?.id == id else {
            if case .success(let opened) = result { await opened.session.close() }
            return
        }
        opening = nil
        let answered = waiters
        waiters = [:]
        if case .success(let opened) = result {
            if let read = opened.folders { folders = read }
            if users.isEmpty {
                await opened.session.close()
            } else {
                session = opened.session
            }
        }
        for waiter in answered.values { waiter.resume(returning: result) }
    }

    /// Sets whether a session window to this host is streaming; a running batch follows at its
    /// next request.
    public nonisolated func setStreaming(_ streaming: Bool) {
        pipeline.setWindow(streaming ? Pipeline.streamingWindow : Pipeline.fullWindow)
    }

    /// The asker of the oldest user who has one, when a channel's sign-in asks.
    func currentAsker() -> (any SignInAsker)? {
        users.keys.sorted().lazy.compactMap { self.users[$0]?.asker }.first
    }

    private func startOpening() {
        session = nil
        nextOpening += 1
        let id = nextOpening
        let (channels, host, ledger) = (channels, host, ledger)
        let (readsFolders, removesLeftovers) = (folders == nil, running == nil)
        let asker: (any SignInAsker)? = currentAsker() == nil ? nil : UsersAsker(files: self)
        opening = (
            id,
            Task {
                let result = await Self.open(
                    channels: channels, asker: asker, host: host, ledger: ledger,
                    readsFolders: readsFolders, removesLeftovers: removesLeftovers)
                await finishOpening(id, result)
            }
        )
    }

    private static func open(
        channels: FilesChannels, asker: (any SignInAsker)?, host: String, ledger: TemporaryLedger,
        readsFolders: Bool, removesLeftovers: Bool
    ) async -> Result<Opened, FilesError> {
        let connection: any ByteConnection
        do {
            connection = try await channels.files(asker).connect()
        } catch {
            return .failure(FilesError(transport: error))
        }
        let session: SFTPSession
        do {
            session = try await SFTPSession.start(over: connection)
        } catch {
            return .failure(error)
        }
        async let folders =
            readsFolders
            ? HostFoldersCommand.read(
                over: channels.command(HostFoldersCommand.remoteCommand, asker), on: session)
            : nil
        // An abandoned opening leaves the leftovers to the next: a try may be running by now.
        if removesLeftovers, !Task.isCancelled {
            await RemoteLeftovers.remove(await ledger.remoteEntries(for: host), on: session, ledger: ledger)
        }
        return .success(Opened(session: session, folders: await folders))
    }
}

/// Puts a channel's sign-in question to the oldest user with an asker when it asks, so a
/// window that left doesn't hold the question.
struct UsersAsker: SignInAsker {
    let files: HostFiles

    func ask(_ question: SignInQuestion) async -> SignInAnswer {
        guard let asker = await files.currentAsker() else { return .cancel }
        return await asker.ask(question)
    }
}
