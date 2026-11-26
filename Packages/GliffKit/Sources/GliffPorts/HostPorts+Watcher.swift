import GliffTransport
import Synchronization
import os

/// The watcher: one channel on a spare place running `PortWatchCommand`, read by
/// `PortListParser`. It never writes to the channel, and closes it to stop.
///
/// - It takes a spare place only when one is free, and waits for `.placeFreed` when none is,
///   when the host refuses the channel, or when a tab takes the place (a yield is no failure).
/// - The channel ending, or overflowing, is a failure: it restarts after 5, 10, 20 then 40 s,
///   and the fifth failure in a row stops it for this attachment. A run that read a frame starts
///   the count again.
/// - A host without `/proc/net/tcp` makes it `.unavailable`, with no restart.
extension HostPorts {
    static let restartDelays: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(40)]

    /// How one channel's run ended: for good, with what detection becomes, or as a failure.
    enum RunEnd {
        case ended(PortDetection)
        case failed(sawFrame: Bool)
    }

    /// Starts the watcher on the attached connection, unless one runs.
    func startWatcher() {
        guard let lease, watcher == nil, !isFinished else { return }
        placeWasFreed = false
        watcher = Task { await self.watch(on: lease) }
    }

    /// Ends the watcher (its channel closes) and forgets this attachment's ports.
    func endWatch() {
        watcher?.cancel()
        watcher = nil
        forgetPorts()
        (known, detection) = (nil, .stopped)
    }

    /// Runs on the watcher's task: a cancelled one changes nothing.
    private func watch(on lease: PassiveLease) async {
        let place = SparePlace()
        var ended = PortDetection.waitingForPlace
        if await lease.takeSpare(yield: { await place.yield() }) {
            ended = await restarting(on: lease, place)
            if !place.yielded { await lease.giveBackSpare() }
        }
        guard !Task.isCancelled else { return }
        watcher = nil
        forgetPorts()
        detection = ended
        publish()
        if ended == .waitingForPlace, placeWasFreed { startWatcher() }
    }

    /// Runs channels on the spare place until one ends for good: what detection becomes then.
    private func restarting(on lease: PassiveLease, _ place: SparePlace) async -> PortDetection {
        var failures = 0
        while !Task.isCancelled {
            switch await run(on: lease, place) {
            case .ended(let detection):
                return detection
            case .failed(let sawFrame):
                failures = sawFrame ? 1 : failures + 1
                guard failures <= Self.restartDelays.count else {
                    HostPortsLog.watcherStopped(failures: failures)
                    return .stopped
                }
                // Cancelled, it ends the loop.
                try? await clock.sleep(for: Self.restartDelays[failures - 1])
            }
        }
        return .stopped
    }

    /// One channel, from its opening to its end. A refused channel gives the place back, and
    /// it, like a yield, waits for a freed place.
    private func run(on lease: PassiveLease, _ place: SparePlace) async -> RunEnd {
        guard place.beginOpening() else { return .ended(.waitingForPlace) }
        defer { place.settle() }
        let nonce = PortWatchCommand.nonce()
        let channel: any ByteConnection
        do {
            channel = try await lease.spareChannel(command: PortWatchCommand.make(nonce: nonce))
        } catch .cancelled {
            return .ended(.waitingForPlace)
        } catch .exited(_, .channelRefused) {
            await lease.spareRefused()
            return .ended(.waitingForPlace)
        } catch {
            return .failed(sawFrame: false)
        }
        guard place.hold(channel), !Task.isCancelled else {
            await channel.close()
            await lease.spareChannelEnded()
            return .ended(place.yielded ? .waitingForPlace : .stopped)
        }
        detection = .running
        publish()
        let end = await read(channel, nonce: nonce, lease)
        // A replaced watcher leaves its successor's timers alone.
        if !Task.isCancelled { forgetAbsences() }
        await channel.close()
        await lease.spareChannelEnded()
        return place.yielded ? .ended(.waitingForPlace) : end
    }

    /// Reads the channel's frames until it ends, overflows or says the host can't list ports.
    private func read(_ channel: any ByteConnection, nonce: String, _ lease: PassiveLease) async -> RunEnd {
        var parser = PortListParser(nonce: nonce)
        var sawFrame = false
        defer { HostPortsLog.watcherRead(parser) }
        do {
            for try await chunk in channel.incoming {
                for output in parser.feed(chunk) {
                    guard !Task.isCancelled else { return .ended(.stopped) }
                    switch output {
                    case .frame(let frame):
                        sawFrame = true
                        take(frame)
                    case .unavailable:
                        return .ended(.unavailable)
                    case .overflow:
                        return .failed(sawFrame: sawFrame)
                    }
                }
            }
        } catch TransportError.exited(_, .channelRefused) where !sawFrame {
            await lease.spareRefused()
            return .ended(.waitingForPlace)
        } catch {}
        return Task.isCancelled ? .ended(.stopped) : .failed(sawFrame: sawFrame)
    }
}

/// The watcher's spare place: the channel on it, closed when a tab takes the place. A tab
/// that takes it while a channel opens waits until that channel is closed, as the host counts
/// it until then.
final class SparePlace: Sendable {
    private struct State {
        var channel: (any ByteConnection)?
        var yielded = false
        var opening = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var yielded: Bool { state.withLock { $0.yielded } }

    /// A channel starts opening on the place; false when the place has gone already.
    func beginOpening() -> Bool {
        state.withLock { state in
            guard !state.yielded else { return false }
            state.opening = true
            return true
        }
    }

    /// Keeps the opened `channel` to close at a yield; false when the place went meanwhile:
    /// then the caller closes it before `settle()`.
    func hold(_ channel: any ByteConnection) -> Bool {
        state.withLock { state in
            guard !state.yielded else { return false }
            state.channel = channel
            return true
        }
    }

    /// The run's channel is closed and none is opening: a yield waiting for one returns.
    func settle() {
        let waiting = state.withLock { state in
            (state.channel, state.opening) = (nil, false)
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    /// A tab takes the place: the channel on it closes, or one opening is waited for.
    func yield() async {
        let channel = state.withLock { state in
            state.yielded = true
            return state.channel
        }
        if let channel {
            await channel.close()
            return
        }
        await withCheckedContinuation { continuation in
            let now = state.withLock { state in
                if state.opening { state.waiting.append(continuation) }
                return !state.opening
            }
            if now { continuation.resume() }
        }
    }
}

extension HostPortsLog {
    static func watcherStopped(failures: Int) {
        GliffPorts.log.info("port watcher stopped after \(failures, privacy: .public) failures")
    }

    static func watcherRead(_ parser: PortListParser) {
        guard parser.droppedFrames > 0 || parser.bytesBeforeFirstFrame > 0 else { return }
        GliffPorts.log.info(
            """
            port watcher: \(parser.droppedFrames, privacy: .public) frames dropped, \
            \(parser.bytesBeforeFirstFrame, privacy: .public) bytes before the first
            """)
    }
}
