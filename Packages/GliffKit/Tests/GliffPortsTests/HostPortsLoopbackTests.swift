import GliffTestSupport
import GliffTransport
import Testing

@testable import GliffPorts

/// Only the person's sockets a forward reaches (loopback or wildcard) count as a port's
/// presence; automatic forwards need a window.
@Suite struct HostPortsLoopbackTests {
    let bench = PortsBench()

    @Test func aPortReboundOnTheWildcardIsOffered() async throws {
        let (tab, hold, channel) = try await bench.watching()
        channel.send([(5173, "node")], lan: [5173])
        #expect(await bench.until { $0.other.map(\.port) == [5173] })
        channel.send([(5173, "node")])
        #expect(await bench.until { $0.notices == [.listening(port: 5173, name: "node")] })
        await hold.end()
        await tab.end()
    }

    @Test func anAutomaticForwardWhosePortLeavesLoopbackStops() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        bench.registry.setAutomatic(true)
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both) })
        channel.send([(5173, "node"), (3000, "node")], lan: [3000])
        #expect(await bench.until { $0.forwarded.first?.listening == false })
        #expect(await bench.clock.waitForSleepers(1))
        bench.clock.advance(by: .seconds(12))
        #expect(await bench.until { $0.forwarded.isEmpty })
        await hold.end()
        await tab.end()
    }

    @Test func aPortStartedWhileTheWatcherWaitedIsOffered() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        let second = try await bench.connections.lease(for: bench.omarchy())
        #expect(await eventually { channel.isClosed })
        await second.end()
        try await bench.channel(1).send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices == [.listening(port: 3000, name: "node")] })
        await hold.end()
        await tab.end()
    }

    @Test func framesAreReadWhileAnAutomaticForwardApplies() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        bench.registry.setAutomatic(true)
        let connection = bench.opener.made[0]
        connection.block(.forward(3000, .ipv4))
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await eventually { connection.isParked(.forward(3000, .ipv4)) })
        channel.send([(5173, "node"), (3000, "node"), (5432, "postgres")])
        #expect(await bench.until { $0.notices == [.listening(port: 5432, name: "postgres")] })
        connection.release(.forward(3000, .ipv4))
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both) })
        await hold.end()
        await tab.end()
    }

    @Test func noWindowNoAutomaticForward() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        bench.registry.setAutomatic(true)
        await hold.end()
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.available.map(\.port) == [3000, 5173] })
        #expect(try await bench.snapshot().forwarded.isEmpty)
        await tab.end()
    }

    @Test func aRefusalThroughItsOutputLeavesNoPlaceCounted() async throws {
        let (tab, hold, channel) = try await bench.watching()
        channel.fail(.exited(status: 255, failure: .channelRefused))
        #expect(await bench.until { $0.detection == .waitingForPlace })
        let second = try await bench.connections.lease(for: bench.omarchy())
        #expect(bench.opener.made.count == 2)
        await second.end()
        await hold.end()
        await tab.end()
    }
}
