import GliffTestSupport
import Testing

@testable import GliffTransport

/// Leases taken with `opening: false`, as a start macro's: they take a place only on a
/// connection already open with room, and never open one.
@Suite struct HostConnectionsOpeningTests {
    let clock = ManualClock()
    let opener = FakeOpener()

    func connections(leaseLimit: Int = 10) -> HostConnections {
        HostConnections(open: opener.open, clock: clock, leaseLimit: leaseLimit)
    }

    func omarchy() throws -> SSHTarget { try SSHTarget("omarchy") }

    static let noRoom = TransportError.exited(status: 255, failure: .noRoomOnConnection)

    /// A lease that may not open takes a place only on a connection already open with room.
    @Test func notOpeningTakesOnlyAnOpenConnection() async throws {
        let hosts = connections(leaseLimit: 1)
        let target = try omarchy()
        await #expect(throws: Self.noRoom) { try await hosts.lease(for: target, opening: false) }
        #expect(opener.calls == 0)
        let first = try await hosts.lease(for: target)
        await #expect(throws: Self.noRoom) { try await hosts.lease(for: target, opening: false) }
        await first.end()
        let again = try await hosts.lease(for: target, opening: false)
        #expect(opener.calls == 1)
        await again.end()
    }

    @Test func notOpeningNeverWaitsForAnOpen() async throws {
        let hosts = connections()
        let target = try omarchy()
        opener.hold()
        async let opened = hosts.lease(for: target)
        #expect(await eventually { opener.waitingCount == 1 })
        await #expect(throws: Self.noRoom) { try await hosts.lease(for: target, opening: false) }
        opener.release()
        _ = try await opened
        #expect(opener.calls == 1)
    }

    /// A refused channel moves a lease that may not open only to a connection open with room.
    @Test func aLeaseThatMayNotOpenNeverMovesToANewConnection() async throws {
        let hosts = connections()
        let target = try omarchy()
        let first = try await hosts.lease(for: target)
        let quiet = try await hosts.lease(for: target, opening: false)
        await #expect(throws: Self.noRoom) { try await quiet.channelRefused() }
        #expect(opener.calls == 1)
        await first.end()
    }

    @Test func aLeaseThatMayNotOpenMovesToOneOpenWithRoom() async throws {
        let hosts = connections()
        let target = try omarchy()
        let held = [
            try await hosts.lease(for: target), try await hosts.lease(for: target),
            try await hosts.lease(for: target),
        ]
        try await held[2].channelRefused()
        #expect(opener.calls == 2)
        await held[0].end()
        let quiet = try await hosts.lease(for: target, opening: false)
        #expect(quiet.current.id == held[1].current.id)
        try await quiet.channelRefused()
        #expect(quiet.current.id == held[2].current.id)
        #expect(opener.calls == 2)
    }

    @Test func aCancelledLeaseThatMayNotOpenTakesNoPlace() async throws {
        let hosts = connections(leaseLimit: 1)
        let target = try omarchy()
        let first = try await hosts.lease(for: target)
        await first.end()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await hosts.lease(for: target, opening: false)
        }
        await #expect(throws: TransportError.cancelled) { try await cancelled.value }
        _ = try await hosts.lease(for: target, opening: false)
    }

    @Test func macroChannelsDontLogStderr() async throws {
        let hosts = connections()
        let lease = try await hosts.lease(for: omarchy())
        _ = try await lease.channel(command: "a")
        _ = try await lease.channel(command: "b", logsStderr: false)
        #expect(opener.made.first?.stderrLogged == [true, false])
    }
}
