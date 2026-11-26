public import GliffTransport

/// The host's queue: one batch at a time, in order, each a user of the channel while it is
/// queued or running; browsing requests go between its requests. The activity is held while
/// any batch is queued or running. Each try first removes the host's leftovers (every
/// temporary the ledger holds for it: a failed try's included), then starts the top-level
/// items earlier tries didn't finish over.
extension HostFiles {
    /// The batches queued, running and ended, in order.
    public var transfers: [TransferBatch] { queue.map(\.batch) }

    /// Whether a batch is queued or running.
    public var hasWork: Bool { queue.contains { $0.user != nil } }

    /// Queues `request`; `asker` answers a sign-in its channel needs.
    public func enqueue(_ request: TransferRequest, asker: (any SignInAsker)?) -> TransferBatch {
        let batch = TransferBatch(request: request)
        queue.append(QueuedBatch(batch: batch, user: join(asker: asker)))
        startNext()
        return batch
    }

    /// Stops the batch: the running one at its next request, a queued one at once.
    public func cancel(_ id: TransferBatch.ID) async {
        if running?.id == id {
            running?.task.cancel()
        } else if let index = index(id), let user = queue[index].user {
            queue[index].user = nil
            queue[index].batch.progress.set(.cancelled)
            await leave(user)
            updateActivity()
        }
    }

    /// Queues a failed batch again. `asker` and `clash` are the window that tries again: it
    /// answers a sign-in the batch needs and, for an upload that asks, a taken name (an upload
    /// that keeps both still does).
    public func retry(_ id: TransferBatch.ID, asker: (any SignInAsker)?, clash: NameClashPolicy = .keepBoth) {
        guard let index = index(id), case .failed = queue[index].batch.progress.counts.state else { return }
        queue[index].user = join(asker: asker)
        if case .ask = queue[index].clash { queue[index].clash = clash }
        queue[index].batch.progress.set(.queued)
        startNext()
    }

    /// Takes an ended batch off the list and, when connected with no try running, removes the
    /// host's leftovers; otherwise the next try or session does.
    public func dismiss(_ id: TransferBatch.ID) async {
        guard let index = index(id), queue[index].user == nil else { return }
        queue.remove(at: index)
        guard running == nil, let session, await !session.isEnded else { return }
        let leftovers = await ledger.remoteEntries(for: host)
        // A try that starts from here on records nothing it hasn't fetched a session for.
        guard running == nil else { return }
        await RemoteLeftovers.remove(leftovers, on: session, ledger: ledger)
    }

    func index(_ id: TransferBatch.ID) -> Int? { queue.firstIndex { $0.batch.id == id } }

    /// Starts the first queued batch when none is running.
    func startNext() {
        if running == nil,
            let next = queue.first(where: { $0.batch.progress.counts.state == .queued })
        {
            let id = next.batch.id
            next.batch.progress.restart()
            running = (id, Task { await self.run(id) })
        }
        updateActivity()
    }

    private func updateActivity() {
        if hasWork, activityToken == nil {
            activityToken = activity.begin()
        } else if !hasWork, let token = activityToken {
            activity.end(token)
            activityToken = nil
        }
    }

    /// One try of the batch.
    private func run(_ id: TransferBatch.ID) async {
        guard let index = index(id), let user = queue[index].user else { return }
        let entry = queue[index]
        let state: TransferState
        do throws(FilesError) {
            try await attempt(entry, as: user)
            state = .finished
        } catch .cancelled {
            state = .cancelled
        } catch {
            state = .failed(error)
        }
        if let index = self.index(id) {
            queue[index].done += entry.batch.progress.counts.topLevelDone
            queue[index].user = nil
            // Only a failed batch is tried again, from its plan.
            switch state {
            case .failed: break
            default: queue[index].plan = nil
            }
        }
        entry.batch.progress.set(state)
        running = nil
        startNext()
        await leave(user)
    }

    /// Off the actor: planning walks this Mac's folders.
    private nonisolated func attempt(_ entry: QueuedBatch, as user: FilesUser) async throws(FilesError) {
        let session = try await session(for: user)
        await RemoteLeftovers.remove(await ledger.remoteEntries(for: host), on: session, ledger: ledger)
        let plan: QueuedBatch.Plan
        if let planned = entry.plan {
            plan = planned
        } else {
            plan = try await Self.plan(entry.batch.request, on: session)
            await keep(plan, for: entry.batch.id)
        }
        let progress = entry.batch.progress
        switch plan {
        case .upload(let plan):
            let rest = plan.droppingTopLevel(entry.done)
            progress.begin(rest)
            try await Upload(
                session: session, host: host, ledger: ledger, pipeline: pipeline, progress: progress,
                clash: entry.clash
            ).run(rest)
        case .download(let plan):
            let rest = plan.droppingTopLevel(entry.done)
            progress.begin(rest)
            try await Download(session: session, ledger: ledger, pipeline: pipeline, progress: progress).run(
                rest)
        }
    }

    private static func plan(_ request: TransferRequest, on session: SFTPSession) async throws(FilesError)
        -> QueuedBatch.Plan
    {
        switch request {
        case .upload(let urls, let destination, _):
            .upload(try UploadPlan.upload(urls, to: destination))
        case .download(let paths, let destination):
            .download(try await DownloadPlan.download(paths, on: session, to: destination))
        }
    }

    private func keep(_ plan: QueuedBatch.Plan, for id: TransferBatch.ID) {
        if let index = index(id) { queue[index].plan = plan }
    }
}
