import GliffTestSupport
import GliffTransport
import Testing

@testable import GliffPorts

/// HostPorts keeps a host's forwards while a window holds it: applied on its connection,
/// waiting through a reconnect, moved when their port is taken, and cancelled after the grace.
@Suite struct HostPortsForwardsTests {
    let clock = ManualClock()
    let connectionClock = ManualClock()
    let opener = PortsOpener()
    let mac = PortsMac()
    let connections: HostConnections
    let registry: PortsRegistry

    init() {
        connections = HostConnections(open: opener.open, clock: connectionClock, leaseLimit: 1)
        registry = PortsRegistry(connections: connections, clock: clock, check: mac.check, pick: mac.pick)
    }

    func omarchy() throws -> SSHTarget { try SSHTarget("omarchy") }

    static func forward(_ local: Int, remote: Int? = nil) -> PortForward {
        PortForward(localPort: local, destination: .localhost, remotePort: remote ?? local)!
    }

    static func both(_ port: Int) -> [PortsCall] { [.forward(port, .ipv4), .forward(port, .ipv6)] }

    static func configured(_ port: Int, bind: String? = nil) -> ConfiguredForwards {
        ConfiguredForwards(local: [ConfiguredForward(forward: forward(port), bind: bind)], notApplied: [])
    }

    func rows() async throws -> [ForwardRow] {
        try await #require(await registry.ports(for: omarchy())).snapshot.forwarded
    }

    func state(of port: Int) async throws -> ForwardState? {
        try await rows().first { $0.remotePort == port }?.state
    }

    @Test func theFirstHoldAttachesAndApplies() async throws {
        opener.configure(Self.configured(8080))
        let tab = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        let ports = try #require(await registry.ports(for: omarchy()))
        await ports.forward(remote: 3000, destination: .localhost, localPort: nil)
        #expect(opener.made[0].calls == Self.both(8080) + Self.both(5173) + Self.both(3000))
        #expect(try await rows().map(\.kind) == [.config, .saved, .manual])
        #expect(try await state(of: 5173) == .active(local: 5173, loopbacks: .both))
        await hold.end()
        await tab.end()
    }

    @Test func anIPv6FailureLeavesIPv4Only() async throws {
        let tab = try await connections.lease(for: omarchy())
        opener.made[0].answer(.forward(5173, .ipv6), with: .failed)
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        #expect(try await state(of: 5173) == .active(local: 5173, loopbacks: .ipv4Only))
        await hold.end()
        await tab.end()
    }

    @Test func aLostConnectionMakesForwardsWait() async throws {
        _ = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        opener.made[0].lose()
        #expect(await eventually { (try? await state(of: 5173)) == .waiting })
        await hold.end()
    }

    @Test func theNextOpenReappliesOnTheSamePort() async throws {
        _ = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        opener.made[0].lose()
        #expect(await eventually { (try? await state(of: 5173)) == .waiting })
        _ = try await connections.lease(for: omarchy(), fresh: true)
        #expect(await eventually { (try? await state(of: 5173)) == .active(local: 5173, loopbacks: .both) })
        #expect(opener.made[1].calls == Self.both(5173))
        #expect(try await #require(await registry.ports(for: omarchy())).snapshot.notices.isEmpty)
        await hold.end()
    }

    @Test func aTakenPortMovesAndSaysSo() async throws {
        _ = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        opener.made[0].lose()
        #expect(await eventually { (try? await state(of: 5173)) == .waiting })
        mac.take(5173)
        _ = try await connections.lease(for: omarchy(), fresh: true)
        #expect(await eventually { (try? await state(of: 5173)) == .active(local: 5174, loopbacks: .both) })
        let snapshot = try await #require(await registry.ports(for: omarchy())).snapshot
        let id = try #require(snapshot.forwarded.first?.id)
        #expect(snapshot.notices == [.moved(id: id, remote: 5173, from: 5173, to: 5174)])
        await hold.end()
    }

    @Test func forwardsMoveToAnotherLiveConnection() async throws {
        _ = try await connections.lease(for: omarchy())
        let second = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        #expect(opener.made[0].calls == Self.both(5173))
        opener.made[0].lose()
        #expect(await eventually { opener.made[1].calls == Self.both(5173) })
        #expect(try await state(of: 5173) == .active(local: 5173, loopbacks: .both))
        await hold.end()
        await second.end()
    }

    @Test func theGraceCancelsEveryForward() async throws {
        let tab = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        await hold.end()
        await hold.end()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(9))
        #expect(try await registry.ports(for: omarchy()) != nil)
        clock.advance(by: .seconds(1))
        #expect(await eventually { (try? await registry.ports(for: omarchy())) == nil })
        #expect(opener.made[0].calls == Self.both(5173) + [.cancel(5173, .ipv4), .cancel(5173, .ipv6)])
        await tab.end()
    }

    @Test func aHoldBackWithinTheGraceKeepsThem() async throws {
        let tab = try await connections.lease(for: omarchy())
        let first = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        let ports = try #require(await registry.ports(for: omarchy()))
        await first.end()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(5))
        let second = await registry.hold(try omarchy(), saved: [])
        clock.advance(by: .seconds(10))
        #expect(try await registry.ports(for: omarchy()) === ports)
        #expect(opener.made[0].calls == Self.both(5173))
        await second.end()
        await tab.end()
    }

    @Test func savedForwardsStayUntilTheLastHoldEnds() async throws {
        let tab = try await connections.lease(for: omarchy())
        let first = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        let second = await registry.hold(try omarchy(), saved: [])
        await first.end()
        #expect(try await rows().map(\.remotePort) == [5173])
        await second.end()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        #expect(await eventually { (try? await registry.ports(for: omarchy())) == nil })
        await tab.end()
    }

    @Test func aBusyConfigPortFailsWithTryAgain() async throws {
        opener.configure(Self.configured(8080))
        let tab = try await connections.lease(for: omarchy())
        opener.made[0].answer(.forward(8080, .ipv4), with: .localPortInUse)
        let hold = await registry.hold(try omarchy(), saved: [])
        #expect(try await state(of: 8080) == .failed(.localPortInUse))
        let row = try #require(try await rows().first)
        try await #require(await registry.ports(for: omarchy())).retry(row.id)
        #expect(try await state(of: 8080) == .active(local: 8080, loopbacks: .both))
        await hold.end()
        await tab.end()
    }

    @Test func aConfigPortTheCheckFindsTakenFails() async throws {
        opener.configure(Self.configured(8080))
        mac.take(8080)
        let tab = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [])
        #expect(try await state(of: 8080) == .failed(.localPortInUse))
        #expect(opener.made[0].calls.isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test func aTimedOutForwardIsCancelledBeforeItsRetry() async throws {
        let tab = try await connections.lease(for: omarchy())
        opener.made[0].answer(.forward(5173, .ipv4), with: .timedOut)
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        #expect(
            opener.made[0].calls == [.forward(5173, .ipv4), .cancel(5173, .ipv4)] + Self.both(5173))
        #expect(try await state(of: 5173) == .active(local: 5173, loopbacks: .both))
        await hold.end()
        await tab.end()
    }

    @Test func underTenTwentyFourIsNotApplied() async throws {
        opener.configure(ConfiguredForwards(local: [], notApplied: ["localforward 80 localhost:80"]))
        let tab = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [])
        let snapshot = try await #require(await registry.ports(for: omarchy())).snapshot
        #expect(snapshot.notApplied == ["localforward 80 localhost:80"])
        #expect(snapshot.forwarded.isEmpty)
        #expect(opener.made[0].calls.isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test(arguments: [
        ("*", true), ("0.0.0.0", true), ("", true), ("localhost", false), ("127.0.0.1", false), (nil, false),
    ])
    func aWildcardConfigBindIsFlagged(_ bind: String?, _ flagged: Bool) async throws {
        opener.configure(Self.configured(8080, bind: bind))
        let tab = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [])
        #expect(try await rows().first?.bindNotLoopback == flagged)
        await hold.end()
        await tab.end()
    }

    @Test func getScreensAloneTakesNoHold() async throws {
        let tab = try await connections.lease(for: omarchy())
        await tab.end()
        #expect(try await registry.ports(for: omarchy()) == nil)
        #expect(opener.made[0].calls.isEmpty)
    }

    @Test func aStoppedForwardIsCancelledOnBothLoopbacks() async throws {
        let tab = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        let row = try #require(try await rows().first)
        try await #require(await registry.ports(for: omarchy())).stop(row.id)
        #expect(opener.made[0].calls == Self.both(5173) + [.cancel(5173, .ipv4), .cancel(5173, .ipv6)])
        #expect(try await rows().isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test func snapshotsFollowTheHost() async throws {
        let tab = try await connections.lease(for: omarchy())
        var snapshots = registry.snapshots(for: try omarchy()).makeAsyncIterator()
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        var last: PortsSnapshot?
        while let snapshot = await snapshots.next() {
            last = snapshot
            if snapshot.forwarded.first?.state == .active(local: 5173, loopbacks: .both) { break }
        }
        #expect(last?.forwarded.map(\.remotePort) == [5173])
        await hold.end()
        await tab.end()
    }
}
