import GliffTestSupport
import Testing

@testable import GliffPorts
@testable import GliffTransport

/// HostPorts while its connection changes, or its grace runs out, in the middle of its work.
extension HostPortsForwardsTests {
    /// Waits until a blocked call on `connection` is waiting.
    func parked(_ call: PortsCall?, on connection: PortsFakeConnection) async -> Bool {
        await eventually { connection.isParked(call) }
    }

    func ports() async throws -> HostPorts { try #require(await registry.ports(for: omarchy())) }

    @Test(arguments: [Loopback.ipv4, .ipv6])
    func aForwardInFlightAsItsConnectionEndsGoesToTheNext(_ loopback: Loopback) async throws {
        _ = try await connections.lease(for: omarchy())
        let second = try await connections.lease(for: omarchy())
        let first = opener.made[0]
        first.block(.forward(5173, loopback))
        let holding = Task { await registry.hold(try omarchy(), saved: [Self.forward(5173)]) }
        #expect(await parked(.forward(5173, loopback), on: first))
        let ports = try await ports()
        let lease = await ports.lease
        first.lose()
        #expect(await eventually { await ports.lease !== lease })
        first.release(.forward(5173, loopback))
        #expect(await eventually { opener.made[1].calls == Self.both(5173) })
        #expect(await eventually { (try? await state(of: 5173)) == .active(local: 5173, loopbacks: .both) })
        try await holding.value.end()
        await second.end()
    }

    @Test func aConnectionEndingWhileAttachingAttachesTheNext() async throws {
        _ = try await connections.lease(for: omarchy())
        let second = try await connections.lease(for: omarchy())
        let first = opener.made[0]
        first.block(nil)
        let holding = Task { await registry.hold(try omarchy(), saved: [Self.forward(5173)]) }
        #expect(await parked(nil, on: first))
        let ports = try await ports()
        first.lose()
        #expect(await eventually { await ports.lease == nil })
        first.release(nil)
        #expect(await eventually { opener.made[1].calls == Self.both(5173) })
        try await holding.value.end()
        await second.end()
    }

    @Test func aForwardInFlightAsTheGraceEndsIsCancelled() async throws {
        let tab = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [])
        let ports = try await ports()
        opener.made[0].block(.forward(5173, .ipv6))
        let forwarding = Task { await ports.forward(remote: 5173, destination: .localhost, localPort: nil) }
        #expect(await parked(.forward(5173, .ipv6), on: opener.made[0]))
        await hold.end()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        opener.made[0].release(.forward(5173, .ipv6))
        _ = await forwarding.value
        #expect(await eventually { (try? await registry.ports(for: omarchy())) == nil })
        #expect(opener.made[0].calls == Self.both(5173) + [.cancel(5173, .ipv4), .cancel(5173, .ipv6)])
        await tab.end()
    }

    @Test func aSecondTimeoutIsCancelledToo() async throws {
        let tab = try await connections.lease(for: omarchy())
        opener.made[0].answer(.forward(5173, .ipv6), with: .timedOut)
        opener.made[0].answer(.forward(5173, .ipv6), with: .timedOut)
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        let ipv6: [PortsCall] = [.forward(5173, .ipv6), .cancel(5173, .ipv6)]
        #expect(opener.made[0].calls == [.forward(5173, .ipv4)] + ipv6 + ipv6)
        #expect(try await state(of: 5173) == .active(local: 5173, loopbacks: .ipv4Only))
        await hold.end()
        await tab.end()
    }

    /// The grace has run out and its forwards are being cancelled.
    func expiring() async throws {
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        opener.made[0].block(.cancel(5173, .ipv4))
        await hold.end()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        #expect(await parked(.cancel(5173, .ipv4), on: opener.made[0]))
    }

    @Test func aHoldAsTheGraceEndsWaitsForItsCancels() async throws {
        let tab = try await connections.lease(for: omarchy())
        try await expiring()
        let old = try await ports()
        let holding = Task { await registry.hold(try omarchy(), saved: [Self.forward(5173)]) }
        #expect(await eventually { await old.endWaiters?.count == 1 })
        opener.made[0].release(.cancel(5173, .ipv4))
        let hold = try await holding.value
        let cancels: [PortsCall] = [.cancel(5173, .ipv4), .cancel(5173, .ipv6)]
        #expect(opener.made[0].calls == Self.both(5173) + cancels + Self.both(5173))
        await hold.end()
        await tab.end()
    }

    @Test func holdsAsTheGraceEndsShareOneHostPorts() async throws {
        let tab = try await connections.lease(for: omarchy())
        try await expiring()
        let old = try await ports()
        let one = Task { await registry.hold(try omarchy(), saved: []) }
        let two = Task { await registry.hold(try omarchy(), saved: []) }
        #expect(await eventually { await old.endWaiters?.count == 2 })
        opener.made[0].release(.cancel(5173, .ipv4))
        let (first, second) = (try await one.value, try await two.value)
        let ports = try await ports()
        #expect(first.ports === ports && second.ports === ports)
        await first.end()
        await second.end()
        await tab.end()
    }

    @Test func holdsTogetherFollowTheConnectionsOnce() async throws {
        let tab = try await connections.lease(for: omarchy())
        async let one = registry.hold(try omarchy(), saved: [])
        async let two = registry.hold(try omarchy(), saved: [])
        let (first, second) = try await (one, two)
        #expect(await connections.sinks[try omarchy().value]?.count == 1)
        await first.end()
        await second.end()
        await tab.end()
    }

    @Test func aSavedPortTheConfigForwardsIsKeptOnce() async throws {
        opener.configure(Self.configured(5173))
        let tab = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        #expect(try await rows().map(\.kind) == [.config])
        #expect(opener.made[0].calls == Self.both(5173))
        await hold.end()
        await tab.end()
    }
}
