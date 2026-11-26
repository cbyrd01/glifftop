import Foundation
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
