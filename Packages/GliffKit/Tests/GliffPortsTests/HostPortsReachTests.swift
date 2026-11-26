import GliffTestSupport
import GliffTransport
import Testing

@testable import GliffPorts

/// What the host's ports say only while the watcher reads them, and only of forwards to the
/// host itself; the registry's automatic setting.
@Suite struct HostPortsReachTests {
    let bench = PortsBench()

    @Test func aForwardElsewhereLeavesTheHostsPort() async throws {
        let (tab, hold, _) = try await bench.firstFrame([(5173, "node"), (8080, "python3")])
        let elsewhere = ForwardDestination.address(PortListParserTests.ip("10.0.0.2"))
        try await bench.ports().forward(remote: 8080, destination: elsewhere, localPort: nil)
        let snapshot = try await bench.snapshot()
        #expect(snapshot.available.map(\.port) == [5173, 8080])
        #expect(snapshot.forwarded.map(\.listening) == [false])
        #expect(snapshot.forwarded.first?.name == nil)
        await hold.end()
        await tab.end()
    }

    @Test func portsGoWhenTheWatcherStops() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices.count == 1 })
        channel.sendNone()
        #expect(await bench.until { $0.detection == .unavailable })
        let snapshot = try await bench.snapshot()
        #expect(snapshot.available.isEmpty && snapshot.other.isEmpty && snapshot.notices.isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test func anAbsenceEndsWithItsChannel() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        await bench.registry.setAutomatic(true)
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both) })
        channel.send([(5173, "node")])
        #expect(await bench.clock.waitForSleepers(1))
        channel.end()
        #expect(await eventually { (try? await bench.ports().absent.isEmpty) ?? false })
        #expect(await bench.clock.waitForSleepers(1))
        bench.clock.advance(by: .seconds(12))
        _ = try await bench.channel(1)
        #expect(try await bench.row(3000)?.state == .active(local: 3000, loopbacks: .both))
        await hold.end()
        await tab.end()
    }

    @Test func aStoppingForwardIsNotTimed() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        await bench.registry.setAutomatic(true)
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both) })
        let id = try #require(try await bench.row(3000)?.id)
        let connection = bench.opener.made[0]
        connection.block(.cancel(3000, .ipv4))
        let stopping = Task { try await bench.ports().stop(id) }
        #expect(await eventually { connection.isParked(.cancel(3000, .ipv4)) })
        channel.send([(5173, "node")])
        #expect(await bench.until { $0.forwarded.first?.listening == false })
        connection.release(.cancel(3000, .ipv4))
        try await stopping.value
        #expect(try await bench.ports().absent.isEmpty)
        await hold.end()
        await tab.end()
    }

    @Test func aSecondStopLeavesTheFirstToFinish() async throws {
        let (tab, hold, _) = try await bench.firstFrame([(5173, "node")])
        let id = try #require(
            await bench.ports().forward(remote: 5173, destination: .localhost, localPort: nil))
        let connection = bench.opener.made[0]
        connection.block(.cancel(5173, .ipv4))
        let first = Task { try await bench.ports().stop(id) }
        #expect(await eventually { connection.isParked(.cancel(5173, .ipv4)) })
        try await bench.ports().stop(id)
        #expect(try await bench.row(5173)?.state == .stopping)
        connection.release(.cancel(5173, .ipv4))
        try await first.value
        #expect(try await bench.row(5173) == nil)
        await hold.end()
        await tab.end()
    }

    @Test func theRegistryKeepsTheAutomaticSetting() async throws {
        await bench.registry.setAutomatic(true)
        let (tab, hold, _) = try await bench.watching()
        #expect(try await bench.ports().automatic)
        await bench.registry.setAutomatic(false)
        #expect(try await !bench.ports().automatic)
        await hold.end()
        await tab.end()
    }
}
