import Foundation
import GliffMachines
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
    /// Reconnect Now was asked for: the next try asks for a sign-in again, as the person's own.
    var asked = false
    let network: AsyncStream<Bool>
    let networkChanges: AsyncStream<Bool>.Continuation

    init() { (network, networkChanges) = AsyncStream.makeStream() }
}

/// Trying a lost session again, with backoff (`Reconnector`): a session that streamed and ended
/// with a reason a retry may fix, its machine's Reconnect automatically on. Each try is a new
/// session to the same destination and options, in the same window, its size and full screen
/// kept, the last picture dimmed under `ReconnectingView` meanwhile; a Focused Monitor mirror's
/// asks for the monitor it last showed while the host has it (`ReconnectScreen`). A session that drops within
/// `ReconnectMemory.steadyTime` of coming back goes on from its count. Disconnect, closing the
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
            run.asked = true
            // During a try it does nothing: the next automatic try isn't the person's.
            Task { if await run.reconnector?.reconnectNow() == false { run.asked = false } }
        } else if phase == .ended {
            tryAgain()
        } else if phase == .streaming, !quitting {
            // Asked for: it counts afresh.
            reconnectMemory.forget()
            endSession(abandoningAQuietLink: true)
            beginReconnect(after: .connectionLost, now: true)
        }
    }

    /// Whether a session starting asks for a sign-in again (`HostConnections`' fresh lease):
    /// one the person started does, a reconnect's try only after Reconnect Now, a revived one
    /// never.
    func asksAgain(_ reconnecting: Bool) -> Bool {
        guard reconnecting else { return true }
        guard let run = reconnectRun else { return false }
        defer { run.asked = false }
        return run.asked
    }

    /// Whether Reconnect has something to do.
    var canReconnect: Bool { isActive && (isReconnecting || canTryAgain || isInterrupted) }

    /// Whether the ended session has a destination to try again (a session that failed to
    /// start has none).
    var canTryAgain: Bool { phase == .ended && destination != nil }

    /// Try Again on the ended screen: a new session to the same destination, with the window's
    /// options (the screen the sheet saved since, if any; else the window's own, asked for as a
    /// reconnect's try asks).
    func tryAgain() {
        guard let destination else { return }
        start(destination, screen: sheetScreen ?? screenChoice, restoring: sheetScreen == nil)
    }

    /// The monitor the window shows, or is about to: a reconnecting Focused Monitor mirror's, the
    /// one its try asks for (`ReconnectScreen`). Show All Monitors' planning and placement read it.
    var shownMonitor: String? { reconnectScreen.monitor(shownBy: screenChoice, output: outputName) }

    /// A session that asked for the monitor a Focused Monitor mirror last showed ended with it
    /// missing (`ReconnectScreen`): the same try, or Try Again, asks for the focused monitor at
    /// once, its end never shown nor counted as a reconnect's try.
    func restartsFocused(after end: SessionEnd, on destination: SSHTarget, reconnecting: Bool) -> Bool {
        guard !quitting, reconnectScreen.forgetsMissing(end) else { return false }
        start(destination, screen: screenChoice, reconnecting: reconnecting, restoring: true)
        return true
    }

    /// Another window's session to this destination streams again after this one's reconnect
    /// gave up: a try on the connection now up, keeping the window's size, as a reconnect's
    /// would. One that fails still says the reconnect gave up, and is revived again.
    func revive() {
        guard gaveUp, canTryAgain, let destination else { return }
        start(destination, screen: screenChoice, reconnecting: true)
    }

    /// The session's phase changed: a try's session streamed or ended, or a session that may
    /// be tried again ended.
    func sessionPhaseChanged() {
        // A monitor's mirror while streaming: the pointer hands over between the destination's.
        capture.handoverGroup = phase == .streaming && !isVirtual ? destination?.value : nil
        switch phase {
        case .streaming:
            gaveUp = false
            reconnectScreen.streamed(screenChoice, output: outputName)
            resumeAttempt(.streaming)
            if let destination { OpenSessions.shared.reached(destination, by: self) }
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

    /// Stops a reconnect under way, its try's session included (the caller ends that). Any
    /// connection the person makes, or Disconnect, comes here: the next reconnect counts afresh.
    func cancelReconnect() {
        reconnectMemory.forget()
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

    /// The network path changed: a countdown stops while it's unusable, and a probe waiting
    /// is withdrawn (the path can turn unusable just after a wake's probe, as Wi-Fi rejoins); a
    /// usable one probes the link again, and that probe decides.
    func networkChanged(_ usable: Bool) {
        networkUsable = usable
        reconnectRun?.networkChanges.yield(usable)
        if usable { probe() } else { session?.withdrawProbe() }
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
        heldPicture = lastPicture
        (reconnectEnd, gaveUp) = (end, false)
        let run = ReconnectRun()
        // A window gone, or a run since replaced, ends with a reason that is never retried.
        let reconnector = Reconnector(memory: reconnectMemory) { [weak self, weak run] in
            guard let run else { return .ended(.disconnected) }
            return await self?.attempt(for: run) ?? .ended(.disconnected)
        }
        run.reconnector = reconnector
        (run.skipsFirstWait, run.asked) = (now, now)
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
        let held = heldPicture
        clearReconnect()
        switch result {
        case .reconnected:
            // The new session's picture may still be held: the last one stays until it shows.
            if shownStream == nil, held != nil {
                heldPicture = held
                refreshHasPicture()
            }
            if screenChoice == .virtual { showVirtualNotice() }
            // The new session ended before this arrived: it is tried again too.
            if phase == .ended { sessionPhaseChanged() }
        case .gaveUp: gaveUp = true
        case .cancelled: break
        }
    }

    /// A picture shows: a reconnect's held picture gives way to it, and a later reconnect
    /// holds it. A session that ends before its picture shows (held) leaves the last one.
    func showing(_ stream: StreamInfo) {
        lastPicture = (slot, stream)
        if heldPicture != nil { heldPicture = nil }
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
