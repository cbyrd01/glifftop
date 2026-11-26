import GliffTestSupport
import GliffTransport
import Testing

@testable import GliffPorts

/// HostPorts at its edges: a forward stopped across a reconnect, a connection that fails
/// without ending, the top of the port range, and a forward asked of one that has ended.
extension HostPortsForwardsTests {
    @Test func aForwardBeingStoppedStaysStoppedThroughAReconnect() async throws {
        _ = try await connections.lease(for: omarchy())
        let second = try await connections.lease(for: omarchy())
        let first = opener.made[0]
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        let ports = try await ports()
        let row = try #require(try await rows().first)
        first.block(.cancel(5173, .ipv4))
        let stopping = Task { await ports.stop(row.id) }
        #expect(await parked(.cancel(5173, .ipv4), on: first))
        let lease = await ports.lease
        first.lose()
        #expect(
            await eventually {
                let now = await ports.lease
                return now !== lease && now != nil
            })
        first.release(.cancel(5173, .ipv4))
        await stopping.value
        #expect(try await rows().isEmpty)
        #expect(opener.made[1].calls.isEmpty)
        await hold.end()
        await second.end()
    }

    @Test func aConnectionLostWithoutAnEndAttachesAtTheNextOpen() async throws {
        let tab = try await connections.lease(for: omarchy())
        opener.made[0].answer(.forward(5173, .ipv4), with: .connectionLost)
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(5173)])
        #expect(try await state(of: 5173) == .waiting)
        let fresh = try await connections.lease(for: omarchy(), fresh: true)
        #expect(await eventually { (try? await state(of: 5173)) == .active(local: 5173, loopbacks: .both) })
        await hold.end()
        await fresh.end()
        await tab.end()
    }

    @Test func aRemotePortOutOfRangeFails() async throws {
        let tab = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [])
        try await ports().forward(remote: 70000, destination: .localhost, localPort: nil)
        #expect(try await state(of: 70000) == .failed(.failed))
        await hold.end()
        await tab.end()
    }

    @Test func aRefusedTopPortMovesBelowIt() async throws {
        let tab = try await connections.lease(for: omarchy())
        opener.made[0].answer(.forward(65535, .ipv4), with: .localPortInUse)
        opener.made[0].answer(.forward(65535, .ipv4), with: .localPortInUse)
        let hold = await registry.hold(try omarchy(), saved: [Self.forward(65535)])
        #expect(try await state(of: 65535) == .active(local: 50001, loopbacks: .both))
        await hold.end()
        await tab.end()
    }

    @Test func aForwardAskedOfEndedPortsIsRefused() async throws {
        let tab = try await connections.lease(for: omarchy())
        let hold = await registry.hold(try omarchy(), saved: [])
        let ports = try await ports()
        await hold.end()
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(10))
        #expect(await eventually { (try? await registry.ports(for: omarchy())) == nil })
        #expect(await ports.forward(remote: 3000, destination: .localhost, localPort: nil) == nil)
        await tab.end()
    }
}
