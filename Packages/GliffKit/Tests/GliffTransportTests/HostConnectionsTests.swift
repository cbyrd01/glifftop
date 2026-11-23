import GliffTestSupport
import Synchronization
import Testing

@testable import GliffTransport

@Suite struct HostConnectionsTests {
    let clock = ManualClock()
    let opener = FakeOpener()

    func connections(leaseLimit: Int = 10) -> HostConnections {
        HostConnections(open: opener.open, clock: clock, leaseLimit: leaseLimit)
    }

    func omarchy() throws -> SSHTarget { try SSHTarget("omarchy") }

    @Test func concurrentLeasesShareOneOpen() async throws {
        let hosts = connections()
        let target = try omarchy()
        opener.hold()
        async let first = hosts.lease(for: target)
        async let second = hosts.lease(for: target)
        #expect(await eventually { opener.waitingCount == 1 })
        opener.release()
        let (a, b) = try await (first, second)
        #expect(opener.calls == 1)
        _ = try await a.channel(command: "a")
        _ = try await b.channel(command: "b")
        #expect(opener.made.first?.commands == ["a", "b"])
    }

    @Test func aLeaseReusesAnOpenConnection() async throws {
        let hosts = connections()
        _ = try await hosts.lease(for: omarchy())
        _ = try await hosts.lease(for: omarchy())
        #expect(opener.calls == 1)
    }

    @Test func anotherDestinationOpensItsOwn() async throws {
        let hosts = connections()
        _ = try await hosts.lease(for: omarchy())
        _ = try await hosts.lease(for: SSHTarget("me@omarchy"))
        #expect(opener.calls == 2)
    }

    @Test func theConnectionClosesTenSecondsAfterTheLastLease() async throws {
        let hosts = connections()
        let lease = try await hosts.lease(for: omarchy())
        let connection = try #require(opener.made.first)
        await lease.end()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .milliseconds(9900))
        try await Task.sleep(for: .milliseconds(50))
        #expect(connection.closeCount == 0)
        clock.advance(by: .milliseconds(100))
        #expect(await eventually { connection.closeCount == 1 })
    }

    @Test func aLeaseDuringTheGraceKeepsItOpen() async throws {
        let hosts = connections()
        try await hosts.lease(for: omarchy()).end()
        let connection = try #require(opener.made.first)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(5))
        let again = try await hosts.lease(for: omarchy())
        #expect(await clock.waitForSleepers(0))
        clock.advance(by: .seconds(10))
        try await Task.sleep(for: .milliseconds(50))
        #expect(connection.closeCount == 0)
        #expect(opener.calls == 1)
        _ = again
    }

    @Test func anOpenFinishingWithNoLeaseIsClosed() async throws {
        let hosts = connections()
        let target = try omarchy()
        opener.hold()
        let leasing = Task { try await hosts.lease(for: target) }
        #expect(await eventually { opener.waitingCount == 1 })
        leasing.cancel()
        await #expect(throws: TransportError.cancelled) { try await leasing.value }
        opener.release()
        #expect(await eventually { opener.made.count == 1 })
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        #expect(await eventually { opener.made.first?.closeCount == 1 })
    }

    @Test func aLostConnectionIsRebuiltOnce() async throws {
        let hosts = connections()
        let target = try omarchy()
        _ = try await hosts.lease(for: target)
        try #require(opener.made.first).lose(.unreachable)
        #expect(await eventually { await hosts.connectionCount(for: target) == 0 })
        async let a = hosts.lease(for: target)
        async let b = hosts.lease(for: target)
        async let c = hosts.lease(for: target)
        _ = try await (a, b, c)
        #expect(opener.calls == 2)
    }

    @Test func aFailedSignInAnswersForTenSeconds() async throws {
        let hosts = connections()
        let target = try omarchy()
        let refused = TransportError.exited(status: 255, failure: .agentRefused)
        opener.failNext(refused)
        await #expect(throws: refused) { try await hosts.lease(for: target) }
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(5))
        await #expect(throws: refused) { try await hosts.lease(for: target) }
        #expect(opener.calls == 1)
        clock.advance(by: .seconds(5))
        #expect(await eventually { (try? await hosts.lease(for: target)) != nil })
        #expect(opener.calls == 2)
    }

    @Test func anEleventhLeaseOpensAFurtherConnection() async throws {
        let hosts = connections()
        let target = try omarchy()
        var leases: [HostLease] = []
        for _ in 0..<11 { leases.append(try await hosts.lease(for: target)) }
        #expect(opener.calls == 2)
        await leases[0].end()
        let twelfth = try await hosts.lease(for: target)
        _ = try await twelfth.channel(command: "twelfth")
        #expect(opener.made.first?.commands == ["twelfth"])
        #expect(opener.calls == 2)
    }

    @Test func aRefusedChannelMovesTheLease() async throws {
        let hosts = connections()
        let target = try omarchy()
        let leases = [
            try await hosts.lease(for: target), try await hosts.lease(for: target),
            try await hosts.lease(for: target),
        ]
        try await leases[2].channelRefused()
        #expect(opener.calls == 2)
        _ = try await leases[2].channel(command: "moved")
        #expect(opener.made.last?.commands == ["moved"])
        _ = try await hosts.lease(for: target).channel(command: "fourth")
        #expect(opener.made.first?.commands.contains("fourth") == false)
    }

    @Test func aSilentChannelInvalidates() async throws {
        let hosts = connections()
        let lease = try await hosts.lease(for: omarchy())
        await lease.channelSilent()
        #expect(opener.made.first?.invalidateCount == 1)
    }

    @Test func closeAllEndsEveryConnection() async throws {
        let hosts = connections()
        let held = try await hosts.lease(for: omarchy())
        try await hosts.lease(for: SSHTarget("box")).end()
        await hosts.closeAll()
        #expect(opener.made.map(\.closeCount) == [1, 1])
        _ = try await hosts.lease(for: omarchy())
        #expect(opener.calls == 3)
        _ = held
    }

    /// Quitting with several hosts waits for the slowest `-O exit`, not their sum.
    @Test func closeAllEndsThemTogether() async throws {
        let hosts = connections()
        let gate = CloseGate()
        opener.holdCloses(gate)
        let first = try await hosts.lease(for: omarchy())
        let second = try await hosts.lease(for: SSHTarget("box"))
        let closing = Task { await hosts.closeAll() }
        #expect(await eventually { opener.made.map(\.closeCount) == [1, 1] })
        gate.open()
        await closing.value
        _ = (first, second)
    }

    @Test func aLeaseEndedWhileMovingGivesItsPlaceBack() async throws {
        let hosts = connections()
        let lease = try await hosts.lease(for: omarchy())
        opener.hold()
        let moving = Task { try await lease.channelRefused() }
        #expect(await eventually { opener.waitingCount == 1 })
        await lease.end()
        opener.release()
        try await moving.value
        #expect(await clock.waitForSleepers(2))
        clock.advance(by: .seconds(10))
        #expect(await eventually { opener.made.map(\.closeCount) == [1, 1] })
    }

    @Test func aRefusalAfterTheEndMovesNothing() async throws {
        let hosts = connections()
        let lease = try await hosts.lease(for: omarchy())
        await lease.end()
        try await lease.channelRefused()
        #expect(opener.calls == 1)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        #expect(await eventually { opener.made.first?.closeCount == 1 })
    }

    @Test func aFailedFurtherOpenDoesNotBlockAFreePlace() async throws {
        let hosts = connections(leaseLimit: 1)
        let target = try omarchy()
        let first = try await hosts.lease(for: target)
        opener.failNext(.exited(status: 255, failure: .agentRefused))
        await #expect(throws: TransportError.self) { try await hosts.lease(for: target) }
        await first.end()
        _ = try await hosts.lease(for: target)
        #expect(opener.calls == 2)
    }

    @Test func closeAllCancelsThoseWaitingForAnOpen() async throws {
        let hosts = connections()
        let target = try omarchy()
        opener.hold()
        let leasing = Task { try await hosts.lease(for: target) }
        #expect(await eventually { opener.waitingCount == 1 })
        let closing = Task { await hosts.closeAll() }
        await #expect(throws: TransportError.cancelled) { try await leasing.value }
        #expect(opener.calls == 1)
        #expect(await eventually { opener.cancelledCount == 1 })
        opener.release()
        await closing.value
        #expect(opener.made.first?.closeCount == 1)
    }

    /// Quitting during a sign-in: closeAll returns only once the open it cancelled has ended,
    /// so no master outlives the app.
    @Test func closeAllWaitsForTheOpenItCancels() async throws {
        let hosts = connections()
        let target = try omarchy()
        opener.hold()
        let leasing = Task { try await hosts.lease(for: target) }
        #expect(await eventually { opener.waitingCount == 1 })
        let closed = Mutex(false)
        let closing = Task {
            await hosts.closeAll()
            closed.withLock { $0 = true }
        }
        #expect(await eventually { opener.cancelledCount == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!closed.withLock { $0 })
        opener.release()
        await closing.value
        #expect(opener.made.first?.closeCount == 1)
        _ = try? await leasing.value
    }

    @Test func anIdleHostIsForgotten() async throws {
        let hosts = connections()
        let target = try omarchy()
        try await hosts.lease(for: target).end()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        #expect(await eventually { await hosts.hostCount == 0 })
    }

    /// Only a sign-in that asked something (an agent's approval) is remembered: an unreachable
    /// host is tried again at once.
    @Test func aFailureThatAskedNothingIsNotRemembered() async throws {
        let hosts = connections()
        opener.failNext(.exited(status: 255, failure: .unreachable))
        await #expect(throws: TransportError.self) { try await hosts.lease(for: omarchy()) }
        _ = try await hosts.lease(for: omarchy())
        #expect(opener.calls == 2)
    }

    @Test func aFreshLeaseAsksAgain() async throws {
        let hosts = connections()
        opener.failNext(.exited(status: 255, failure: .agentRefused))
        await #expect(throws: TransportError.self) { try await hosts.lease(for: omarchy()) }
        _ = try await hosts.lease(for: omarchy(), fresh: true)
        #expect(opener.calls == 2)
    }

    /// Cancel while the 1Password prompt is up: the sign-in stops too.
    @Test func anOpenNobodyWaitsForIsCancelled() async throws {
        let hosts = connections()
        let target = try omarchy()
        opener.hold()
        let leasing = Task { try await hosts.lease(for: target) }
        #expect(await eventually { opener.waitingCount == 1 })
        leasing.cancel()
        await #expect(throws: TransportError.cancelled) { try await leasing.value }
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(1))
        #expect(await eventually { opener.cancelledCount == 1 })
        opener.release()
    }

    /// Connect pressed while Get Screens signs in: the listing stops, and the session waits for
    /// the same sign-in, not a second prompt.
    @Test func anOpenLeftBrieflyIsKeptForTheNextAsker() async throws {
        let hosts = connections()
        let target = try omarchy()
        opener.hold()
        let listing = Task { try await hosts.lease(for: target) }
        #expect(await eventually { opener.waitingCount == 1 })
        listing.cancel()
        await #expect(throws: TransportError.cancelled) { try await listing.value }
        #expect(await clock.waitForSleepers(1))
        let session = Task { try await hosts.lease(for: target) }
        #expect(await clock.waitForSleepers(0))
        clock.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(50))
        opener.release()
        _ = try await session.value
        #expect(opener.calls == 1)
        #expect(opener.cancelledCount == 0)
    }
}
