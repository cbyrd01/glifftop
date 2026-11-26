public import GliffTransport

/// Which connections a run may use (spec 4.1): `fresh` and `asker` as `HostConnections.lease`'s,
/// and `opening: false` for a place on a connection already open only.
public struct MacroAccess: Sendable {
    public let fresh: Bool
    public let asker: (any SignInAsker)?
    public let opening: Bool

    public init(fresh: Bool = false, asker: (any SignInAsker)? = nil, opening: Bool = true) {
        (self.fresh, self.asker, self.opening) = (fresh, asker, opening)
    }
}

/// Runs one macro on a one-shot channel (spec 4.1 to 4.5): writes its text once, reads to the
/// first trailer, the channel's end, the Mac's deadline (the limit plus 5 s), 4 MiB, or a
/// cancel, then ends the channel without waiting for it, so the host's 2 s grace never delays
/// the result. Cancelling the task returns `.stopped`.
public struct MacroRunner: Sendable {
    private let connections: HostConnections
    private let target: SSHTarget
    private let clock: any Clock<Duration>

    public init(
        connections: HostConnections, target: SSHTarget, clock: any Clock<Duration> = ContinuousClock()
    ) {
        (self.connections, self.target, self.clock) = (connections, target, clock)
    }

    public func run(_ macro: Macro, context: MacroContext, access: MacroAccess) async -> MacroRun {
        var attempt = Attempt(result: .stopped)
        let duration = await clock.measure {
            attempt = await self.attempt(macro, context: context, access: access)
        }
        return MacroRun(
            result: attempt.result, duration: duration, output: attempt.output?.kept ?? [],
            droppedBytes: attempt.output?.dropped ?? 0, channelError: attempt.channelError)
    }

    /// A run's result, its output, and the channel's own failure when it kept the run from
    /// starting.
    struct Attempt {
        var result: MacroResult
        var output: MacroOutput?
        var channelError: TransportError?
    }

    private func attempt(_ macro: Macro, context: MacroContext, access: MacroAccess) async -> Attempt {
        let token = MacroToken.random()
        let text: [UInt8]
        do {
            text = try MacroScript.text(for: macro.script, context: context, token: token)
        } catch {
            return Attempt(result: .notStarted(.cannotRun))
        }
        let channel = ChannelTransport(
            connections: connections, target: target,
            command: MacroWrapper.commandLine(length: text.count, limit: macro.timeLimit, token: token),
            silenceLimit: .seconds(macro.timeLimit + 10), fresh: access.fresh, asker: access.asker,
            oneShot: true, opening: access.opening, logsStderr: false)
        let connection: any ByteConnection
        do {
            connection = try await channel.connect()
        } catch {
            if Task.isCancelled || error == .cancelled { return Attempt(result: .stopped) }
            return Self.notStarted(by: error)
        }
        // A cancel during the sign-in: the text is never written, so the script never runs.
        if Task.isCancelled {
            await connection.close()
            return Attempt(result: .stopped)
        }
        defer { Task { await connection.close() } }
        // Not awaited: a write that never finishes must not hold off the deadline or a cancel.
        Task { try? await connection.write(text) }
        let (output, ending) = await MacroReading.read(
            connection.incoming, token: token, until: .seconds(macro.timeLimit + 5), on: clock)
        var attempt = Self.attempt(ending, sawStart: output.sawStart, limit: macro.timeLimit)
        attempt.output = output
        return attempt
    }

    /// How a reading's end reads as a result.
    static func attempt(_ ending: MacroReading.Ending, sawStart: Bool, limit: Int) -> Attempt {
        switch ending {
        case .output(.exit(let status)): Attempt(result: .exited(status))
        case .output(.timeout), .deadline: Attempt(result: .timedOut(seconds: limit))
        case .output(.tooLarge): Attempt(result: .outputTooLarge)
        case .cancelled: Attempt(result: .stopped)
        case .channel where sawStart: Attempt(result: .endedWhileRunning)
        case .channel(.exited(MacroWrapper.notReceivedStatus, _)?): Attempt(result: .notReceived)
        case .channel(.exited(MacroWrapper.noHeadStatus, _)?): Attempt(result: .noHead)
        case .channel(let error?) where endedInSSH(error): notStarted(by: error)
        case .channel(nil), .channel(.exited(_, .other)?): Attempt(result: .notStarted(.ranSomethingElse))
        case .channel(let error?): notStarted(by: error)
        }
    }

    /// ssh's own status, 255, or a signal: the connection failed, not the host's command.
    private static func endedInSSH(_ error: TransportError) -> Bool {
        guard case .exited(let status, _) = error else { return false }
        return status == 255 || status < 0
    }

    /// A run the channel kept from starting, with the channel's failure.
    private static func notStarted(by error: TransportError) -> Attempt {
        let kind: NotStartedKind =
            switch error {
            case .exited(_, .noRoomOnConnection): .connectionFull
            case .exited(_, .channelRefused): .refused
            default: .noConnection
            }
        return Attempt(result: .notStarted(kind), channelError: error)
    }
}

/// Feeds a channel's bytes to a `MacroOutput` until it ends the run, the channel ends, or the
/// deadline passes.
enum MacroReading {
    enum Ending: Equatable {
        /// The output ended the run.
        case output(MacroOutput.End)
        /// The channel ended first: nil when it finished normally, else why it failed.
        case channel(TransportError?)
        case deadline
        /// The reading's task was cancelled; a cancel wins over the deadline.
        case cancelled
    }

    private enum Event {
        case read(MacroOutput, failure: TransportError?)
        case deadline
        case sleepEnded
    }

    /// The output read, finished, and how the reading ended. At the deadline or a cancel the
    /// reader stops, since the stream ends when its task is cancelled.
    static func read(
        _ incoming: AsyncThrowingStream<[UInt8], any Error>, token: MacroToken, until limit: Duration,
        on clock: any Clock<Duration>
    ) async -> (MacroOutput, Ending) {
        await withTaskGroup(of: Event.self) { group in
            group.addTask { await drain(incoming, token: token) }
            group.addTask { (try? await clock.sleep(for: limit)) == nil ? .sleepEnded : .deadline }
            var deadline = false
            while let event = await group.next() {
                switch event {
                case .read(let output, let failure):
                    group.cancelAll()
                    if let end = output.end { return (output, .output(end)) }
                    if Task.isCancelled { return (output, .cancelled) }
                    return (output, deadline ? .deadline : .channel(failure))
                case .deadline:
                    deadline = true
                    group.cancelAll()
                case .sleepEnded: continue
                }
            }
            preconditionFailure("the reader always returns")
        }
    }

    private static func drain(_ incoming: AsyncThrowingStream<[UInt8], any Error>, token: MacroToken) async
        -> Event
    {
        var output = MacroOutput(token: token)
        var failure: TransportError?
        do {
            for try await chunk in incoming {
                output.feed(chunk)
                if output.end != nil { break }
            }
        } catch {
            failure = error as? TransportError ?? .writeFailed("the channel failed")
        }
        output.finish()
        return .read(output, failure: failure)
    }
}
