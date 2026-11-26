import Foundation
import GliffTransport
import Testing

@testable import GliffMachines

/// A machine's ports forwarded when connected, as the app stores them.
@Suite struct SavedForwardTests {
    private func decode(_ json: String) throws -> MachineOptions {
        try JSONDecoder().decode(MachineOptions.self, from: Data(json.utf8))
    }

    @Test func aSavedForwardRoundTrips() throws {
        let forwards = [
            try #require(SavedForward(remotePort: 5173, destination: "localhost", localPort: 5174)),
            try #require(SavedForward(remotePort: 8080, destination: "::1", localPort: nil)),
            try #require(SavedForward(remotePort: 9000, destination: "127.0.0.2", localPort: nil)),
        ]
        let options = MachineOptions(forwards: forwards)
        let decoded = try JSONDecoder().decode(MachineOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded == options)
        #expect(decoded.forwards == forwards)
    }

    @Test func anOlderStoreDecodesWithNoForwards() throws {
        #expect(try decode(#"{"scaleToFit": true}"#).forwards == [])
        #expect(try decode(#"{"forwards": 5}"#).forwards == [])
        #expect(try decode(#"{"forwards": 5, "scaleToFit": true}"#).scaleToFit)
    }

    @Test func anInvalidEntryIsDroppedAndTheRestKept() throws {
        let json = """
            {"forwards": [
                {"remotePort": 5173, "destination": "localhost"},
                {"remotePort": 0, "destination": "localhost"},
                {"remotePort": 70000, "destination": "localhost"},
                {"remotePort": 8080, "destination": "localhost", "localPort": 80},
                {"remotePort": 8080, "destination": "localhost", "localPort": 70000},
                {"destination": "localhost"},
                "5173",
                {"remotePort": 3000, "destination": "127.0.0.1", "localPort": 3001}
            ]}
            """
        #expect(
            try decode(json).forwards.map { [$0.remotePort, $0.localPort ?? 0] } == [
                [5173, 0], [3000, 3001],
            ])
    }

    @Test func aRecordKeepsTheMachinesForwards() throws {
        let saved = MachineOptions(forwards: [
            try #require(SavedForward(remotePort: 5173, destination: "localhost", localPort: 5174))
        ])
        let window = MachineOptions(scaleToFit: true)
        #expect(
            window.recorded(over: saved, keepsScreen: false, keepsClipboard: false).forwards == saved.forwards
        )
    }

    @Test func aDestinationIsStoredInOneSpelling() throws {
        let spellings = ["::1", "0::1", "0:0:0:0:0:0:0:1"].map {
            SavedForward(remotePort: 8080, destination: $0, localPort: nil)?.destination
        }
        #expect(spellings == ["::1", "::1", "::1"])
        #expect(
            SavedForward(remotePort: 8080, destination: "LocalHost", localPort: nil)?.destination
                == "localhost")
    }

    @Test func aRepeatedForwardIsKeptOnce() throws {
        let json = """
            {"forwards": [
                {"remotePort": 8080, "destination": "::1", "localPort": 8080},
                {"remotePort": 8080, "destination": "0::1"},
                {"remotePort": 8080, "destination": "localhost"}
            ]}
            """
        #expect(try decode(json).forwards.map(\.destination) == ["::1", "localhost"])
    }

    /// A forward kept from the one running, and back: only to the host or an address, never to
    /// a name the ssh_config gave.
    @Test func aRunningForwardIsKeptAndComesBack() throws {
        let address = try #require(IPLiteral("2001:db8::1"))
        let saved = try #require(SavedForward(.address(address), remotePort: 5173, localPort: 5174))
        #expect(saved.destination == "2001:db8::1")
        #expect(saved.forwardDestination == .address(address))
        #expect(saved.forwards(.address(address), 5173))
        #expect(!saved.forwards(.localhost, 5173))
        #expect(!saved.forwards(.address(address), 5174))
        #expect(SavedForward(.localhost, remotePort: 80, localPort: nil)?.forwardDestination == .localhost)
        let configured = try #require(ForwardDestination(configuredHost: "db"))
        #expect(SavedForward(configured, remotePort: 5432, localPort: nil) == nil)
    }

    /// Forward When Connected adds a forward with its Mac port, and again removes it.
    @Test func forwardWhenConnectedToggles() throws {
        var options = MachineOptions()
        options.toggleForwardWhenConnected(.localhost, 5173, localPort: 5174)
        #expect(options.forwardsWhenConnected(.localhost, 5173))
        #expect(options.forwards.map(\.localPort) == [5174])
        options.toggleForwardWhenConnected(.localhost, 5173, localPort: 5180)
        #expect(!options.forwardsWhenConnected(.localhost, 5173))
        #expect(options.forwards.isEmpty)
        let configured = try #require(ForwardDestination(configuredHost: "db"))
        options.toggleForwardWhenConnected(configured, 5432, localPort: nil)
        #expect(options.forwards.isEmpty)
    }

    /// The machine sheet's add field: a port on the host itself, kept once.
    @Test func aTypedPortIsAddedOnce() throws {
        var options = MachineOptions()
        let added = [" 5173 ", "5173", "0", "65536", "web"].map { options.addForwardWhenConnected($0) }
        #expect(added == [true, false, false, false, false])
        #expect(options.forwardsWhenConnected(.localhost, 5173))
        #expect(options.forwards.map(\.localPort) == [nil])
        #expect(options.forwardToAdd("8080")?.remotePort == 8080)
        #expect(options.forwardToAdd("5173") == nil)
        // The host's own port kept through another loopback is the same port.
        let ipv6 = try #require(SavedForward(remotePort: 8000, destination: "::1", localPort: nil))
        options.forwards.append(ipv6)
        #expect(options.forwardToAdd("8000") == nil)
    }

    @Test func aHostNameDestinationIsRefused() throws {
        #expect(SavedForward(remotePort: 5173, destination: "omarchy", localPort: nil) == nil)
        #expect(SavedForward(remotePort: 5173, destination: "", localPort: nil) == nil)
        #expect(SavedForward(remotePort: 5173, destination: "[::1]", localPort: nil) == nil)
        #expect(SavedForward(remotePort: 5173, destination: "fe80::1%lo0", localPort: nil) == nil)
        #expect(SavedForward(remotePort: 5173, destination: "127.0.0.1 ", localPort: nil) == nil)
        let json = #"{"forwards": [{"remotePort": 5173, "destination": "omarchy"}]}"#
        #expect(try decode(json).forwards == [])
    }
}
