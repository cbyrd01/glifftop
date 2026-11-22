import Foundation
import GliffSession
import GliffTransport
import GliffVideo

/// One reconnect under way: its `Reconnector`, the task running it, the try waiting for its
/// session to stream or end, and the network's changes, passed on in order.
final class ReconnectRun {
    /// Set once, right after the run is made: its tries need the run.
    var reconnector: Reconnector?
    var task: Task<Void, Never>?
    var waiter: CheckedContinuation<ReconnectAttempt, Never>?
    /// Reconnect Now before the first countdown began: it is cut short as it starts.
    var skipsFirstWait = false
    let network: AsyncStream<Bool>
    let networkChanges: AsyncStream<Bool>.Continuation

    init() { (network, networkChanges) = AsyncStream.makeStream() }
}

/// Trying a lost session again, with backoff (`Reconnector`): a session that streamed and ended
/// with a reason a retry may fix, its machine's Reconnect automatically on. Each try is a new
/// session to the same destination and options, in the same window, its size and full screen
/// kept, the last picture dimmed under `ReconnectingView` meanwhile. Disconnect, closing the
/// window, quitting or another connection cancels it. A wake probes the link and cuts the
/// countdown short; the network's state stops and restarts it.
extension SessionModel {
    /// Set while a lost session is tried again: the last picture stays, dimmed.
    var isReconnecting: Bool { reconnectRun != nil }

    /// The slot the video view draws: the last picture's while reconnecting.
    var shownSlot: PictureSlot { heldPicture?.slot ?? slot }

    /// Probes the link (after a wake or a network change), while streaming.
    func probe() {
        session?.probe()
    }

    /// Reconnect Now, Connection ▸ Reconnect (⇧⌘R): cuts a countdown short; on a quiet link,
    /// ends the session and tries at once; after an end, Try Again.
    func reconnectNow() {
        if let run = reconnectRun {
            Task { await run.reconnector?.reconnectNow() }
        } else if phase == .ended {
            tryAgain()
        } else if phase == .streaming, !quitting {
            endSession()
            beginReconnect(after: .connectionLost, now: true)
        }
    }

    /// Whether Reconnect has something to do.
    var canReconnect: Bool { isActive && (isReconnecting || canTryAgain || isInterrupted) }

    /// Whether the ended session has a destination to try again (a session that failed to
    /// start has none).
    var canTryAgain: Bool { phase == .ended && destination != nil }

    /// Try Again on the ended screen: a new session to the same destination, with the window's
    /// options (the screen the sheet saved since, if any).
    func tryAgain() {
        guard let destination else { return }
        start(destination, screen: sheetScreen ?? screenChoice)
    }

    /// The session's phase changed: a try's session streamed or ended, or a session that may
    /// be tried again ended.
    func sessionPhaseChanged() {
        switch phase {
        case .streaming:
            heldPicture = nil
            resumeAttempt(.streaming)
        case .ended:
            let end = snapshot.end ?? .connectionLost
            if reconnectRun?.waiter != nil {
                resumeAttempt(.ended(end))
            } else if reconnectRun == nil, recorded, reconnects, end.mayReconnect, !quitting {
                beginReconnect(after: end)
            }
        default: break
        }
    }

    /// Stops a reconnect under way, its try's session included (the caller ends that).
    func cancelReconnect() {
        guard let run = reconnectRun else { return }
        reconnectRun = nil
        run.task?.cancel()
        run.networkChanges.finish()
        if let waiter = run.waiter {
            run.waiter = nil
            waiter.resume(returning: .ended(.disconnected))
        }
        clearReconnect()
    }

    /// The Mac woke: with the network up, the link is probed and a countdown cut short (a try
    /// while it's down would only spend one).
    func woke() {
        guard networkUsable else { return }
        probe()
        if let run = reconnectRun { Task { await run.reconnector?.reconnectNow() } }
    }

    /// The network path changed: a countdown stops while it's unusable; a usable one probes the
    /// link again (Wi-Fi can take longer than a probe to come back after a wake).
    func networkChanged(_ usable: Bool) {
        networkUsable = usable
        reconnectRun?.networkChanges.yield(usable)
        if usable { probe() }
    }

    /// Reconnect automatically turned off: a reconnect under way stops, with the try's session,
    /// and the end screen says why the session was lost, with Try Again.
    func reconnectsChanged() {
        guard !reconnects, isReconnecting else { return }
        let lost = reconnectEnd ?? .connectionLost
        cancelReconnect()
        if phase != .streaming { endSession(showing: lost) }
    }

    private func beginReconnect(after end: SessionEnd, now: Bool = false) {
        heldPicture = lastStream.map { (slot, $0) }
        (reconnectEnd, gaveUp) = (end, false)
        let run = ReconnectRun()
        // A window gone, or a run since replaced, ends with a reason that is never retried.
        let reconnector = Reconnector { [weak self, weak run] in
            guard let run else { return .ended(.disconnected) }
            return await self?.attempt(for: run) ?? .ended(.disconnected)
        }
        run.reconnector = reconnector
        run.skipsFirstWait = now
        reconnectRun = run
        refreshHasPicture()
        run.networkChanges.yield(networkUsable)
        run.task = Task { [weak self] in
            // The network's changes reach the reconnector one at a time, in the order seen.
            let network = Task {
                for await usable in run.network { await reconnector.networkAvailable(usable) }
            }
            let states = Task { [weak self] in
                for await state in reconnector.states { self?.reconnectStateChanged(state, run: run) }
            }
            let result = await reconnector.run(after: end)
            states.cancel()
            network.cancel()
            self?.finishReconnect(result, run: run)
        }
    }

    /// One try of `run`: a new session to the same destination, in this window, until it
    /// streams or ends.
    private func attempt(for run: ReconnectRun) async -> ReconnectAttempt {
        guard reconnectRun === run, let destination, !quitting else { return .ended(.disconnected) }
        return await withCheckedContinuation { continuation in
            run.waiter = continuation
            start(destination, screen: screenChoice, reconnecting: true)
        }
    }

    private func resumeAttempt(_ attempt: ReconnectAttempt) {
        guard let run = reconnectRun, let waiter = run.waiter else { return }
        run.waiter = nil
        waiter.resume(returning: attempt)
    }

    private func reconnectStateChanged(_ state: ReconnectState, run: ReconnectRun) {
        guard reconnectRun === run else { return }
        reconnectState = state
        if case .waiting(_, let delay) = state {
            reconnectDeadline = .now + TimeInterval(delay.components.seconds)
        }
        // Reconnect Now on a quiet link tries at once, offline too.
        if run.skipsFirstWait, state.isWait {
            run.skipsFirstWait = false
            Task { await run.reconnector?.reconnectNow() }
        }
    }

    /// How the reconnect ended. One cancelled since has already been put away, and its session
    /// ended by whoever cancelled it.
    private func finishReconnect(_ result: ReconnectResult, run: ReconnectRun) {
        guard reconnectRun === run else { return }
        reconnectRun = nil
        clearReconnect()
        switch result {
        case .reconnected:
            if screenChoice == .virtual { showVirtualNotice() }
            // The new session ended before this arrived: it is tried again too.
            if phase == .ended { sessionPhaseChanged() }
        case .gaveUp: gaveUp = true
        case .cancelled: break
        }
    }

    fileprivate func clearReconnect() {
        (reconnectState, reconnectDeadline, heldPicture) = (nil, nil, nil)
        refreshHasPicture()
    }

    /// A new virtual screen replaced the lost one: said once, for a few seconds.
    private func showVirtualNotice() {
        showsVirtualNotice = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.showsVirtualNotice = false
        }
    }
}

extension ReconnectState {
    /// A countdown or a wait for the network: Reconnect Now ends either.
    fileprivate var isWait: Bool {
        if case .trying = self { false } else { true }
    }
}
