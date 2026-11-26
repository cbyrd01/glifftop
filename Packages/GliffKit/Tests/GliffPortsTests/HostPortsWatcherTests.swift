import GliffTestSupport
import GliffTransport
import Testing

@testable import GliffPorts

/// The watcher: one channel on a spare place, which yields to a tab, restarts with a back-off
/// and stops after five failures in a row.
@Suite struct HostPortsWatcherTests {
    let bench = PortsBench()

    @Test func theWatcherStartsOnASparePlace() async throws {
        let (tab, hold, channel) = try await bench.watching()
        #expect(channel.command.contains("gliff-ports"))
        #expect(await bench.until { $0.detection == .running })
        await hold.end()
        await tab.end()
    }

    @Test func aFullConnectionWaitsForAFreedPlace() async throws {
        let first = try await bench.connections.lease(for: bench.omarchy())
        let second = try await bench.connections.lease(for: bench.omarchy())
        let hold = await bench.registry.hold(try bench.omarchy(), saved: [])
        #expect(await bench.until { $0.detection == .waitingForPlace })
        #expect(bench.opener.made[0].channels.isEmpty)
        await second.end()
        _ = try await bench.channel()
        #expect(await bench.until { $0.detection == .running })
        await hold.end()
        await first.end()
    }

    @Test func aRefusedChannelWaitsForAFreedPlace() async throws {
        let first = try await bench.connections.lease(for: bench.omarchy())
        bench.opener.made[0].refuseChannels(1)
        let hold = await bench.registry.hold(try bench.omarchy(), saved: [])
        #expect(await bench.until { $0.detection == .waitingForPlace })
        await first.end()
        _ = try await bench.channel()
        #expect(await bench.until { $0.detection == .running })
        await hold.end()
    }

    @Test func aYieldedPlaceIsNotAFailure() async throws {
        let (tab, hold, channel) = try await bench.watching()
        let second = try await bench.connections.lease(for: bench.omarchy())
        #expect(await eventually { channel.isClosed })
        #expect(await bench.until { $0.detection == .waitingForPlace })
        #expect(bench.clock.sleeperCount == 0)
        await second.end()
        _ = try await bench.channel(1)
        #expect(await bench.until { $0.detection == .running })
        await hold.end()
        await tab.end()
    }

    @Test func theRestartBacksOffAndStopsAfterFive() async throws {
        let (tab, hold, first) = try await bench.watching()
        var channel = first
        for (index, delay) in [5, 10, 20, 40].enumerated() {
            channel.end()
            #expect(await bench.clock.waitForSleepers(1))
            bench.clock.advance(by: .seconds(delay - 1))
            #expect(bench.opener.made[0].channels.count == index + 1)
            bench.clock.advance(by: .seconds(1))
            channel = try await bench.channel(index + 1)
        }
        channel.end()
        #expect(await bench.until { $0.detection == .stopped })
        #expect(bench.clock.sleeperCount == 0)
        await hold.end()
        await tab.end()
    }

    @Test func aFrameBetweenFailuresStartsTheCountAgain() async throws {
        let (tab, hold, first) = try await bench.watching()
        first.end()
        #expect(await bench.clock.waitForSleepers(1))
        bench.clock.advance(by: .seconds(5))
        let second = try await bench.channel(1)
        second.send([(5173, "node")])
        #expect(await bench.until { $0.available.count == 1 })
        second.end()
        #expect(await bench.clock.waitForSleepers(1))
        bench.clock.advance(by: .seconds(5))
        _ = try await bench.channel(2)
        await hold.end()
        await tab.end()
    }

    @Test func noneMeansUnavailableWithoutRestart() async throws {
        let (tab, hold, channel) = try await bench.watching()
        channel.sendNone()
        #expect(await bench.until { $0.detection == .unavailable })
        #expect(await eventually { channel.isClosed })
        #expect(bench.clock.sleeperCount == 0)
        #expect(bench.opener.made[0].channels.count == 1)
        await hold.end()
        await tab.end()
    }

    @Test func anOverflowEndsTheChannelAsAFailure() async throws {
        let (tab, hold, channel) = try await bench.watching()
        channel.send(lines: Array(repeating: String(repeating: "x", count: 1023), count: 130))
        #expect(await eventually { channel.isClosed })
        #expect(await bench.clock.waitForSleepers(1))
        await hold.end()
        await tab.end()
    }

    @Test func theGraceEndsTheWatcher() async throws {
        let (tab, hold, channel) = try await bench.watching()
        await hold.end()
        #expect(await bench.clock.waitForSleepers(1))
        bench.clock.advance(by: .seconds(10))
        #expect(await eventually { channel.isClosed })
        await tab.end()
    }

    @Test func theGraceEndsOnlyOnceTheChannelIsClosed() async throws {
        let (tab, hold, channel) = try await bench.watching()
        channel.holdClose()
        await hold.end()
        #expect(await bench.clock.waitForSleepers(1))
        bench.clock.advance(by: .seconds(10))
        #expect(await eventually { channel.closeStarted })
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await bench.registry.ports(for: bench.omarchy()) != nil)
        channel.releaseClose()
        #expect(await eventually { (try? await bench.registry.ports(for: bench.omarchy())) == nil })
        await tab.end()
    }

    @Test func anOfferOutlastsAReconnect() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices == [.listening(port: 3000, name: "node")] })
        bench.opener.made[0].lose()
        #expect(await bench.until { $0.notices.isEmpty })
        let next = try await bench.connections.lease(for: bench.omarchy())
        #expect(await eventually { bench.opener.made.dropFirst().first?.channels.isEmpty == false })
        let restarted = try #require(bench.opener.made.dropFirst().first?.channels.first)
        restarted.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices == [.listening(port: 3000, name: "node")] })
        await hold.end()
        await next.end()
        await tab.end()
    }

    @Test func anOfferOutlastsAYieldedPlace() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices == [.listening(port: 3000, name: "node")] })
        let second = try await bench.connections.lease(for: bench.omarchy())
        #expect(await bench.until { $0.detection == .waitingForPlace })
        await second.end()
        let restarted = try await bench.channel(1)
        restarted.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.notices == [.listening(port: 3000, name: "node")] })
        await hold.end()
        await tab.end()
    }
}
