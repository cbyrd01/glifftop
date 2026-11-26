import GliffTestSupport
import GliffTransport
import Testing

@testable import GliffPorts

/// What the person keeps stays theirs: a forward saved is never stopped for absence, a saved
/// forward stopped stays stopped for the attachment, a forward made while waiting is the
/// config's once it forwards that port, and a forward on another Mac port says which it asked.
@Suite struct HostPortsSavedTests {
    let bench = PortsBench()

    @Test func anAutomaticForwardSavedIsNeverStoppedForAbsence() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        bench.registry.setAutomatic(true)
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both) })
        await hold.update(saved: [HostPortsForwardsTests.forward(3000)])
        #expect(try await bench.row(3000)?.kind == .saved)
        channel.send([(5173, "node")])
        #expect(await bench.until { $0.forwarded.first?.listening == false })
        #expect(try await bench.ports().absent.isEmpty)
        bench.clock.advance(by: .seconds(12))
        #expect(try await bench.row(3000)?.state == .active(local: 3000, loopbacks: .both))
        await hold.end()
        await tab.end()
    }

    /// Stopped, a saved forward isn't brought back by another window or the same list again;
    /// unticked everywhere and ticked again, it is.
    @Test func aStoppedSavedForwardStaysStopped() async throws {
        let tab = try await bench.connections.lease(for: bench.omarchy())
        let first = await bench.registry.hold(
            try bench.omarchy(), saved: [HostPortsForwardsTests.forward(5173)])
        let id = try #require(try await bench.row(5173)?.id)
        try await bench.ports().stop(id)
        let second = await bench.registry.hold(
            try bench.omarchy(), saved: [HostPortsForwardsTests.forward(5173)])
        await first.update(saved: [HostPortsForwardsTests.forward(5173)])
        #expect(try await bench.snapshot().forwarded.isEmpty)
        await first.update(saved: [])
        await second.update(saved: [])
        await first.update(saved: [HostPortsForwardsTests.forward(5173)])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 5173, loopbacks: .both) })
        await first.end()
        await second.end()
        await tab.end()
    }

    /// Forwarded while waiting for the first connection, a port the config also forwards is
    /// the config's; one on a Mac port of its own stays.
    @Test func aForwardMadeWhileWaitingIsTheConfigs() async throws {
        let line = ConfiguredForward(forward: HostPortsForwardsTests.forward(6006), bind: nil)
        bench.opener.configure(ConfiguredForwards(local: [line], notApplied: []))
        let hold = await bench.registry.hold(try bench.omarchy(), saved: [])
        let ports = try await bench.ports()
        await ports.forward(remote: 6006, destination: .localhost, localPort: nil)
        await ports.forward(remote: 6006, destination: .localhost, localPort: 7000)
        let tab = try await bench.connections.lease(for: bench.omarchy())
        #expect(
            await bench.until {
                $0.forwarded.map(\.kind) == [.config, .manual]
                    && $0.forwarded.allSatisfy { $0.state != .waiting }
            })
        #expect(try await bench.snapshot().forwarded.map(\.localPort) == [6006, 7000])
        await hold.end()
        await tab.end()
    }

    /// A first forward on another Mac port says which it asked for; a saved one, whose port a
    /// bookmark may name, says so in a notice too.
    @Test func aForwardOnAnotherMacPortSaysWhichItAsked() async throws {
        bench.mac.take(3000, 5173)
        let tab = try await bench.connections.lease(for: bench.omarchy())
        let hold = await bench.registry.hold(
            try bench.omarchy(), saved: [HostPortsForwardsTests.forward(5173)])
        try await bench.ports().forward(remote: 3000, destination: .localhost, localPort: nil)
        let snapshot = try await bench.snapshot()
        #expect(snapshot.forwarded.map(\.localPort) == [5174, 3001])
        #expect(snapshot.forwarded.map(\.movedFrom) == [5173, 3000])
        let saved = try #require(snapshot.forwarded.first?.id)
        #expect(snapshot.notices == [.moved(id: saved, remote: 5173, from: 5173, to: 5174)])
        await hold.end()
        await tab.end()
    }

    /// A forward saved and then stopped stays stopped, whatever made it; a hold that ended
    /// saves nothing, so a window opened after lets it come back.
    @Test func whatTheHoldsSaveDecidesAStop() async throws {
        let tab = try await bench.connections.lease(for: bench.omarchy())
        let first = await bench.registry.hold(try bench.omarchy(), saved: [])
        let ports = try await bench.ports()
        let id = try #require(await ports.forward(remote: 3000, destination: .localhost, localPort: nil))
        await first.update(saved: [HostPortsForwardsTests.forward(3000)])
        await ports.stop(id)
        let second = await bench.registry.hold(
            try bench.omarchy(), saved: [HostPortsForwardsTests.forward(3000)])
        #expect(try await bench.snapshot().forwarded.isEmpty)
        await second.end()
        await first.end()
        let third = await bench.registry.hold(
            try bench.omarchy(), saved: [HostPortsForwardsTests.forward(3000)])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both) })
        await third.end()
        await tab.end()
    }

    /// Saved while its absence stop is under way, an automatic forward comes back as saved.
    @Test func aPortSavedDuringItsAbsenceStopComesBack() async throws {
        let (tab, hold, channel) = try await bench.firstFrame([(5173, "node")])
        bench.registry.setAutomatic(true)
        channel.send([(5173, "node"), (3000, "node")])
        #expect(await bench.until { $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both) })
        bench.opener.made[0].block(.cancel(3000, .ipv4))
        channel.send([(5173, "node")])
        #expect(await bench.clock.waitForSleepers(1))
        bench.clock.advance(by: .seconds(12))
        #expect(await eventually { bench.opener.made[0].isParked(.cancel(3000, .ipv4)) })
        await hold.update(saved: [HostPortsForwardsTests.forward(3000)])
        bench.opener.made[0].release(.cancel(3000, .ipv4))
        #expect(
            await bench.until {
                $0.forwarded.map(\.kind) == [.saved]
                    && $0.forwarded.first?.state == .active(local: 3000, loopbacks: .both)
            })
        await hold.end()
        await tab.end()
    }

    /// The note goes when the forward fails, and never names the chooser's own start for a
    /// port under 1024.
    @Test func theMovedNoteSaysOnlyWhatWasAsked() async throws {
        bench.mac.take(8000, 5173)
        let tab = try await bench.connections.lease(for: bench.omarchy())
        let hold = await bench.registry.hold(
            try bench.omarchy(), saved: [HostPortsForwardsTests.forward(5173)])
        try await bench.ports().forward(remote: 80, destination: .localhost, localPort: nil)
        #expect(try await bench.row(80)?.localPort == 8001)
        #expect(try await bench.row(80)?.movedFrom == nil)
        #expect(try await bench.row(5173)?.movedFrom == 5173)
        bench.opener.made[0].lose()
        #expect(await bench.until { $0.forwarded.allSatisfy { $0.state == .waiting } })
        for port in 5174..<5274 { bench.mac.take(port) }
        bench.mac.take(50001)
        let next = try await bench.connections.lease(for: bench.omarchy())
        #expect(await bench.until { $0.forwarded.first?.state == .failed(.localPortInUse) })
        #expect(try await bench.row(5173)?.movedFrom == nil)
        await hold.end()
        await next.end()
        await tab.end()
    }
}
