import Foundation
import GliffTestSupport
import GliffTransport
import Synchronization
import Testing

@testable import GliffMacros

@Suite(.timeLimit(.minutes(1)))
struct MacroRunnerTests {
    let macro = Macro(name: "Test", moment: .manual, script: "echo hi")
    let context = try! MacroContext(moment: .manual, reconnecting: false, screen: .focused)
    let clock = ManualClock()

    /// Counts the connections `HostConnections` opens.
    final class Opens: Sendable {
        let count = Mutex(0)
    }

    func runner(_ host: any HostConnection, opens: Opens = Opens()) throws -> MacroRunner {
        let connections = HostConnections(open: { _, _ in
            opens.count.withLock { $0 += 1 }
            return host
        })
        return MacroRunner(
            connections: connections, target: try SSHTarget("omarchy"), clock: clock)
    }

    func run(
        _ events: [ScriptedHost.Event], access: MacroAccess = .init(), opens: Opens = Opens(),
        cancelsOnOpen: Bool = false
    ) async throws -> (MacroRun, ScriptedHost) {
        let host = ScriptedHost(events, cancelsOnOpen: cancelsOnOpen)
        let run = try await runner(host, opens: opens).run(macro, context: context, access: access)
        return (run, host)
    }

    /// A run in a task, once it waits on the Mac's deadline.
    func started(_ host: ScriptedHost) async throws -> Task<MacroRun, Never> {
        let runner = try runner(host)
        let task = Task { await runner.run(macro, context: context, access: .init()) }
        #expect(await clock.waitForSleepers(1))
        return task
    }

    @Test func exitAndOutputAreRead() async throws {
        let (run, host) = try await run([.start, .text("hi\n"), .trailer("exit 0")])
        #expect(run.result == .exited(0) && run.result.isSuccess)
        #expect(run.output == Array("hi\n".utf8) && run.droppedBytes == 0)
        #expect(host.channels.map(\.logsStderr) == [false])
        #expect(host.channels.map(\.writes.count) == [1])
        #expect(await within(.seconds(5)) { host.channels.allSatisfy(\.closed) })
    }

    @Test func theMacDeadlineTimesOut() async throws {
        let host = ScriptedHost([.start])
        let task = try await started(host)
        clock.advance(by: .seconds(macro.timeLimit + 5))
        let run = await task.value
        #expect(run.result == .timedOut(seconds: macro.timeLimit))
        #expect(run.duration == .seconds(macro.timeLimit + 5))
        #expect(await within(.seconds(5)) { host.channels.allSatisfy(\.closed) })
    }

    @Test func aTimeoutTrailerTimesOut() async throws {
        let (run, _) = try await run([.start, .trailer("timeout"), .trailer("exit 143")])
        #expect(run.result == .timedOut(seconds: macro.timeLimit))
    }

    @Test func cancelReturnsStopped() async throws {
        let host = ScriptedHost([.start, .text("working")])
        let task = try await started(host)
        task.cancel()
        #expect(await task.value.result == .stopped)
        #expect(await within(.seconds(5)) { host.channels.allSatisfy(\.closed) })
    }

    /// A write that never finishes delays neither the deadline nor a cancel.
    @Test func aStuckWriteStillTimesOutAndStops() async throws {
        let timing = try await started(ScriptedHost([], writeHangs: true))
        clock.advance(by: .seconds(macro.timeLimit + 5))
        #expect(await timing.value.result == .timedOut(seconds: macro.timeLimit))
        let stopping = try await started(ScriptedHost([], writeHangs: true))
        stopping.cancel()
        #expect(await stopping.value.result == .stopped)
    }

    /// A cancel wins over the deadline: it is a stop, which never counts as a failure.
    @Test func aCancelledReadingIsAStop() async {
        let (incoming, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
        defer { continuation.finish() }
        let reading = Task { [clock] () -> MacroReading.Ending in
            withUnsafeCurrentTask { $0?.cancel() }
            return await MacroReading.read(incoming, token: .random(), until: .zero, on: clock).1
        }
        #expect(await reading.value == .cancelled)
        #expect(MacroRunner.attempt(.cancelled, sawStart: true, limit: 10).result == .stopped)
    }

    /// A cancel that comes as the channel opens writes nothing: the script never runs.
    @Test func aCancelAsTheChannelOpensWritesNothing() async throws {
        let (run, host) = try await run([.start, .trailer("exit 0")], cancelsOnOpen: true)
        #expect(run.result == .stopped)
        #expect(host.channels.map(\.writes.count) == [0])
        #expect(await within(.seconds(5)) { host.channels.allSatisfy(\.closed) })
    }

    /// ssh's own status, 255, or a signal, before the start line is the connection's failure.
    @Test(arguments: [Int32(255), -9])
    func aConnectionFailureBeforeTheStartLineIsNoConnection(status: Int32) async throws {
        let failure = TransportError.exited(
            status: status, failure: .other("ssh exited with status \(status)"))
        let (run, _) = try await run([.fail(failure)])
        #expect(run.result == .notStarted(.noConnection))
        #expect(run.channelError == failure)
    }

    @Test(arguments: [(Int32(125), MacroResult.notReceived), (126, .noHead)])
    func theWrappersOwnStatusesBeforeTheStartLine(status: Int32, result: MacroResult) async throws {
        let (run, _) = try await run([
            .fail(.exited(status: status, failure: .other("ssh exited with status \(status)")))
        ])
        #expect(run.result == result)
    }

    @Test func noStartLineAndAnotherStatusIsAForcedCommand() async throws {
        let (failed, _) = try await run([
            .text("forced\n"), .fail(.exited(status: 1, failure: .other("ssh exited with status 1"))),
        ])
        #expect(failed.result == .notStarted(.ranSomethingElse))
        #expect(failed.output == Array("forced\n".utf8))
        let (finished, _) = try await run([.text("forced\n"), .finish])
        #expect(finished.result == .notStarted(.ranSomethingElse))
    }

    /// The text is written once, and a lost master never takes a second lease.
    @Test(arguments: [true, false]) func aLostMasterEndsTheRunWithoutASecondLease(started: Bool) async throws
    {
        let opens = Opens()
        let (run, host) = try await run(
            (started ? [.start] : []) + [.fail(.exited(status: 255, failure: .sharedConnectionLost))],
            opens: opens)
        #expect(run.result == (started ? .endedWhileRunning : .notStarted(.noConnection)))
        #expect(run.channelError == (started ? nil : .exited(status: 255, failure: .sharedConnectionLost)))
        #expect(host.channels.map(\.writes.count) == [1])
        #expect(opens.count.withLock { $0 } == 1)
    }

    @Test func noRoomWithoutOpeningIsNotStarted() async throws {
        let opens = Opens()
        let (run, _) = try await run(
            [.start, .trailer("exit 0")], access: MacroAccess(opening: false), opens: opens)
        #expect(run.result == .notStarted(.connectionFull))
        #expect(opens.count.withLock { $0 } == 0)
    }

    /// The sign-in's own failure is kept, for a `before` run to pass on.
    @Test func aSignInFailureIsNotStartedAndKept() async throws {
        let refused = TransportError.exited(status: 255, failure: .permissionDenied)
        let connections = HostConnections(open: { _, _ throws(TransportError) in throw refused })
        let runner = MacroRunner(connections: connections, target: try SSHTarget("omarchy"), clock: clock)
        let run = await runner.run(macro, context: context, access: MacroAccess(fresh: true))
        #expect(run.result == .notStarted(.noConnection))
        #expect(run.channelError == refused)
    }

    /// Nothing from the host, its output or ssh's words reaches a result's words.
    @Test func resultWordsAreFixed() async throws {
        let marker = "INJECTED-MARKER"
        for events: [ScriptedHost.Event] in [
            [.text(marker), .fail(.exited(status: 3, failure: .other(marker)))],
            [.start, .text(marker), .fail(.exited(status: 255, failure: .other(marker)))],
            [.start, .text(marker), .trailer("exit 2")],
        ] {
            let (run, _) = try await run(events)
            #expect(!run.result.words.contains(marker))
        }
        let all: [MacroResult] = [
            .exited(0), .exited(3), .timedOut(seconds: 10), .outputTooLarge, .notReceived, .noHead,
            .endedWhileRunning, .notStarted(.noConnection), .notStarted(.connectionFull),
            .notStarted(.refused), .notStarted(.ranSomethingElse), .notStarted(.cannotRun), .stopped,
            .notApproved, .badOutputName,
        ]
        for result in all { #expect(!result.words.isEmpty) }
        #expect(MacroResult.exited(3).words == "exit 3")
        #expect(MacroResult.timedOut(seconds: 10).words == "Timed out after 10 s")
        #expect(MacroResult.notApproved.words == "Not run: not approved")
        #expect(all.filter(\.isSuccess) == [.exited(0)])
        #expect(all.filter { !$0.countsAsFailure } == [.exited(0), .stopped, .notApproved])
    }

    #if os(macOS)
        @Test func runsOnTheLocalShell() async throws {
            let local = LocalHostConnection()
            defer { local.killLeftovers() }
            let connections = HostConnections(open: { _, _ in local })
            let runner = MacroRunner(connections: connections, target: try SSHTarget("omarchy"))
            let ok = await runner.run(macro, context: context, access: .init())
            #expect(ok.result == .exited(0))
            #expect(ok.output == Array("hi\n".utf8))
            var failing = macro
            failing.script = "echo no >&2; exit 3"
            let failed = await runner.run(failing, context: context, access: .init())
            #expect(failed.result == .exited(3))
            #expect(failed.output == Array("no\n".utf8))
            await connections.closeAll()
        }
    #endif
}
