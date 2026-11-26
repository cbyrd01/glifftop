import GliffTestSupport
import Synchronization
import Testing

@testable import GliffTransport

/// Passive leases (the port manager's): they never open, never keep a connection, and hold no
/// place but a spare one that yields to a tab.
@Suite struct HostConnectionsPassiveTests {
    let clock = ManualClock()
    let opener = FakeOpener()

    func connections(leaseLimit: Int = 10) -> HostConnections {
        HostConnections(open: opener.open, clock: clock, leaseLimit: leaseLimit)
    }

    func omarchy() throws -> SSHTarget { try SSHTarget("omarchy") }

    /// Ends the connection's last ordinary lease and lets its 10 s grace run out.
    func endAndExpire(_ lease: HostLease) async {
        await lease.end()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
    }

    /// Collects a stream's events as they come.
    final class Events: Sendable {
        private let seen = Mutex<[ConnectionEvent]>([])
        private let task = Mutex<Task<Void, Never>?>(nil)

        init(_ stream: AsyncStream<ConnectionEvent>) {
            let reading = Task { [self] in for await event in stream { seen.withLock { $0.append(event) } } }
            task.withLock { $0 = reading }
        }

        var all: [ConnectionEvent] { seen.withLock { $0 } }
        func stop() { task.withLock { $0?.cancel() } }
    }

    @Test func attachWithNoConnectionIsNil() async throws {
        let hosts = connections()
        #expect(try await hosts.attach(to: omarchy()) == nil)
        #expect(opener.calls == 0)
    }

    @Test func passiveNeverOpens() async throws {
        let hosts = connections()
        let lease = try await hosts.lease(for: omarchy())
        let passive = try #require(await hosts.attach(to: omarchy()))
        try #require(opener.made.first).lose(.sharedConnectionLost)
        let target = try omarchy()
        #expect(await eventually { await hosts.connectionCount(for: target) == 0 })
        #expect(try await hosts.attach(to: omarchy()) == nil)
        await passive.end()
        #expect(opener.calls == 1)
        _ = lease
    }

    @Test func onlyPassiveLeasesLeftStartsTheGrace() async throws {
        let hosts = connections()
        let lease = try await hosts.lease(for: omarchy())
        let connection = try #require(opener.made.first)
        let passive = try #require(await hosts.attach(to: omarchy()))
        await endAndExpire(lease)
        #expect(await eventually { connection.closeCount == 1 })
        await #expect(throws: ForwardError.connectionLost) {
            try await passive.forward(Self.web, on: .ipv4)
        }
    }

    @Test func aSpareIsTakenOnlyWhenFree() async throws {
        let hosts = connections(leaseLimit: 2)
        let first = try await hosts.lease(for: omarchy())
        let second = try await hosts.lease(for: omarchy())
        let passive = try #require(await hosts.attach(to: omarchy()))
        #expect(await passive.takeSpare(yield: {}) == false)
        await second.end()
        #expect(await passive.takeSpare(yield: {}) == true)
        #expect(await passive.takeSpare(yield: {}) == false)
        _ = first
    }

    @Test func aSpareYieldsToATabWithoutAnOpen() async throws {
        let hosts = connections(leaseLimit: 2)
        let first = try await hosts.lease(for: omarchy())
        let passive = try #require(await hosts.attach(to: omarchy()))
        let yielded = Mutex(false)
        #expect(await passive.takeSpare(yield: { yielded.withLock { $0 = true } }))
        let spare = try await passive.spareChannel(command: "watch")
        let second = try await hosts.lease(for: omarchy())
        #expect(yielded.withLock { $0 })
        #expect(opener.calls == 1)
        #expect(second.current.id == first.current.id)
        await #expect(throws: TransportError.cancelled) { try await passive.spareChannel(command: "again") }
        _ = spare
    }

    /// The yield comes while the spare's channel opens: it opens into nothing, and is closed.
    @Test func aSpareYieldedWhileItsChannelOpensIsClosed() async throws {
        let hosts = connections(leaseLimit: 2)
        let first = try await hosts.lease(for: omarchy())
        let connection = try #require(opener.made.first)
        let passive = try #require(await hosts.attach(to: omarchy()))
        #expect(await passive.takeSpare(yield: {}))
        let gate = CloseGate()
        connection.holdChannels(gate)
        let opening = Task { try await passive.spareChannel(command: "watch") }
        #expect(await eventually { gate.waitingCount == 1 })
        let leasing = Task { try await hosts.lease(for: omarchy()) }
        #expect(await eventually { await !hosts.holdsSpare(passive.holder) })
        gate.open()
        // The tab has its place only once the spare's channel is closed: the host counts it.
        let second = try await leasing.value
        #expect(connection.channels.first?.isClosed == true)
        await #expect(throws: TransportError.cancelled) { try await opening.value }
        _ = (first, second)
    }

    /// A tab's channel refused beside a spare: the host counts the spare's channel, so the
    /// spare yields its place to the moving tab, with no open.
    @Test func aRefusedChannelBesideASpareTakesTheSparesPlace() async throws {
        let hosts = connections()
        let first = try await hosts.lease(for: omarchy())
        let second = try await hosts.lease(for: omarchy())
        let passive = try #require(await hosts.attach(to: omarchy()))
        let yielded = Mutex(false)
        #expect(await passive.takeSpare(yield: { yielded.withLock { $0 = true } }))
        _ = try await passive.spareChannel(command: "watch")
        try await second.channelRefused()
        #expect(yielded.withLock { $0 })
        #expect(opener.calls == 1)
        _ = first
    }

    /// A spare whose channel isn't open isn't one of the host's sessions: a refused tab moves on.
    @Test func aSpareWithoutAChannelIsNotCountedWhenATabIsRefused() async throws {
        let hosts = connections()
        let first = try await hosts.lease(for: omarchy())
        let second = try await hosts.lease(for: omarchy())
        let passive = try #require(await hosts.attach(to: omarchy()))
        let yielded = Mutex(false)
        #expect(await passive.takeSpare(yield: { yielded.withLock { $0 = true } }))
        try await second.channelRefused()
        #expect(!yielded.withLock { $0 })
        #expect(opener.calls == 2)
        _ = first
    }

    /// A spare whose channel is still opening is one of the host's sessions: it yields to a
    /// refused tab, which keeps its connection.
    @Test func aSpareWhoseChannelOpensCountsWhenATabIsRefused() async throws {
        let hosts = connections()
        let first = try await hosts.lease(for: omarchy())
        let second = try await hosts.lease(for: omarchy())
        let connection = try #require(opener.made.first)
        let passive = try #require(await hosts.attach(to: omarchy()))
        let yielded = Mutex(false)
        #expect(await passive.takeSpare(yield: { yielded.withLock { $0 = true } }))
        let gate = CloseGate()
        connection.holdChannels(gate)
        let opening = Task { try await passive.spareChannel(command: "watch") }
        #expect(await eventually { gate.waitingCount == 1 })
        let moving = Task { try await second.channelRefused() }
        #expect(await eventually { yielded.withLock { $0 } })
        gate.open()
        try await moving.value
        #expect(opener.calls == 1)
        await #expect(throws: TransportError.cancelled) { try await opening.value }
        _ = first
    }

    /// A connection that opens while an older one closes is announced after that one's end.
    @Test func aNewConnectionIsAnnouncedAfterAClosingOnesEnd() async throws {
        let hosts = connections()
        let gate = CloseGate()
        opener.holdCloses(gate)
        let events = Events(try await hosts.events(for: omarchy()))
        let lease = try await hosts.lease(for: omarchy())
        let old = lease.current.id
        await endAndExpire(lease)
        #expect(await eventually { gate.waitingCount == 1 })
        let new = try await hosts.lease(for: omarchy()).current.id
        #expect(!events.all.contains(.opened(new)))
        gate.open()
        #expect(await eventually { events.all.contains(.opened(new)) })
        let ended = try #require(events.all.firstIndex(of: .ended(old, nil)))
        #expect(ended < (events.all.firstIndex(of: .opened(new)) ?? 0))
        events.stop()
    }

    /// A connection held back while another closes, then closed itself before that one ends,
    /// is never announced: neither opened nor ended.
    @Test func aHeldConnectionClosedBeforeItsTurnIsNeverAnnounced() async throws {
        let hosts = connections()
        let gate = CloseGate()
        opener.holdCloses(gate)
        let events = Events(try await hosts.events(for: omarchy()))
        let lease = try await hosts.lease(for: omarchy())
        let old = lease.current.id
        await endAndExpire(lease)
        #expect(await eventually { gate.waitingCount == 1 })
        let new = try await hosts.lease(for: omarchy()).current.id
        let closing = Task { await hosts.closeAll() }
        #expect(await eventually { gate.waitingCount == 2 })
        gate.open()
        await closing.value
        #expect(await eventually { events.all.contains(.ended(old, nil)) })
        #expect(!events.all.contains(.opened(new)))
        #expect(!events.all.contains(.ended(new, nil)))
        events.stop()
    }

    /// A spare whose channel has ended is no longer one of the host's sessions.
    @Test func aSpareWhoseChannelEndedIsNotCountedWhenATabIsRefused() async throws {
        let hosts = connections()
        let first = try await hosts.lease(for: omarchy())
        let second = try await hosts.lease(for: omarchy())
        let passive = try #require(await hosts.attach(to: omarchy()))
        let yielded = Mutex(false)
        #expect(await passive.takeSpare(yield: { yielded.withLock { $0 = true } }))
        let channel = try await passive.spareChannel(command: "watch")
        await channel.close()
        await passive.spareChannelEnded()
        try await second.channelRefused()
        #expect(!yielded.withLock { $0 })
        #expect(opener.calls == 2)
        _ = first
    }

    /// Followers hear of an end only once the master has closed (and let go of its forwards).
    @Test func anExpiryIsAnnouncedOnceTheConnectionHasClosed() async throws {
        let hosts = connections()
        let gate = CloseGate()
        opener.holdCloses(gate)
        let events = Events(try await hosts.events(for: omarchy()))
        let lease = try await hosts.lease(for: omarchy())
        let id = lease.current.id
        await endAndExpire(lease)
        #expect(await eventually { gate.waitingCount == 1 })
        #expect(!events.all.contains(.ended(id, nil)))
        gate.open()
        #expect(await eventually { events.all.contains(.ended(id, nil)) })
        events.stop()
    }

    @Test func aCloseAllIsAnnouncedOnceTheConnectionHasClosed() async throws {
        let hosts = connections()
        let gate = CloseGate()
        opener.holdCloses(gate)
        let events = Events(try await hosts.events(for: omarchy()))
        let id = try await hosts.lease(for: omarchy()).current.id
        let closing = Task { await hosts.closeAll() }
        #expect(await eventually { gate.waitingCount == 1 })
        #expect(!events.all.contains(.ended(id, nil)))
        gate.open()
        await closing.value
        #expect(await eventually { events.all.contains(.ended(id, nil)) })
        events.stop()
    }

    /// Quitting while a spare yields: the tab's lease is cancelled, and nothing opens.
    @Test func aCloseAllDuringAYieldCancelsTheLease() async throws {
        let hosts = connections(leaseLimit: 2)
        let first = try await hosts.lease(for: omarchy())
        let passive = try #require(await hosts.attach(to: omarchy()))
        #expect(await passive.takeSpare(yield: { await hosts.closeAll() }))
        await #expect(throws: TransportError.cancelled) { try await hosts.lease(for: omarchy()) }
        #expect(opener.calls == 1)
        _ = first
    }

    @Test func attachPrefersAConnectionInUse() async throws {
        let hosts = connections(leaseLimit: 1)
        let idle = try await hosts.lease(for: omarchy())
        let used = try await hosts.lease(for: omarchy())
        await idle.end()
        let passive = try #require(await hosts.attach(to: omarchy()))
        #expect(passive.connectionID == used.current.id)
    }

    @Test func aDroppedPassiveLeaseGivesBackItsSpare() async throws {
        let hosts = connections(leaseLimit: 2)
        let first = try await hosts.lease(for: omarchy())
        do {
            let dropped = try #require(await hosts.attach(to: omarchy()))
            #expect(await dropped.takeSpare(yield: {}))
        }
        let other = try #require(await hosts.attach(to: omarchy()))
        #expect(await eventually { await other.takeSpare(yield: {}) })
        _ = first
    }

    @Test func aFreedPlaceIsAnnounced() async throws {
        let hosts = connections()
        let events = Events(try await hosts.events(for: omarchy()))
        let lease = try await hosts.lease(for: omarchy())
        let id = lease.current.id
        await lease.end()
        #expect(await eventually { events.all.contains(.placeFreed(id)) })
        events.stop()
    }

    @Test func aRefusedSpareLowersTheLimit() async throws {
        let hosts = connections(leaseLimit: 3)
        let first = try await hosts.lease(for: omarchy())
        let passive = try #require(await hosts.attach(to: omarchy()))
        #expect(await passive.takeSpare(yield: {}))
        await passive.spareRefused()
        // The limit is now the one place in use: the next lease opens a further connection.
        _ = try await hosts.lease(for: omarchy())
        #expect(opener.calls == 2)
        #expect(await passive.takeSpare(yield: {}) == false)
        _ = first
    }

    @Test func eventsReportOpenedLostAndClosed() async throws {
        let hosts = connections()
        let events = Events(try await hosts.events(for: omarchy()))
        let lease = try await hosts.lease(for: omarchy())
        let lost = lease.current.id
        try #require(opener.made.first).lose(.sharedConnectionLost)
        #expect(await eventually { events.all.contains(.ended(lost, .sharedConnectionLost)) })
        await lease.end()
        let again = try await hosts.lease(for: omarchy())
        let kept = again.current.id
        await endAndExpire(again)
        #expect(await eventually { events.all.contains(.ended(kept, nil)) })
        #expect(events.all.first == .opened(lost))
        #expect(events.all.contains(.opened(kept)))
        events.stop()
    }

    @Test func closeAllEndsEachConnectionInEvents() async throws {
        let hosts = connections(leaseLimit: 1)
        let events = Events(try await hosts.events(for: omarchy()))
        let a = try await hosts.lease(for: omarchy())
        let b = try await hosts.lease(for: omarchy())
        await hosts.closeAll()
        #expect(await eventually { events.all.contains(.ended(a.current.id, nil)) })
        #expect(await eventually { events.all.contains(.ended(b.current.id, nil)) })
        events.stop()
    }

    @Test func forwardsGoToThePassiveLeasesConnection() async throws {
        let hosts = connections()
        let lease = try await hosts.lease(for: omarchy())
        let connection = try #require(opener.made.first)
        let configured = ConfiguredForwards(local: [], notApplied: ["dynamicforward 1080"])
        connection.configuredForwards = configured
        let passive = try #require(await hosts.attach(to: omarchy()))
        #expect(passive.connectionID == lease.current.id)
        try await passive.forward(Self.web, on: .ipv6)
        try await passive.cancel(Self.web, on: .ipv6)
        #expect(connection.forwardCalls == [.forward(Self.web, .ipv6), .cancel(Self.web, .ipv6)])
        #expect(await passive.configuredForwards == configured)
    }

    static let web = PortForward(localPort: 5173, destination: .localhost, remotePort: 5173)!
}
