import Foundation
import GliffTransport
import Testing

@testable import GliffPorts

/// The addresses and destinations as the popover shows, opens and copies them.
@Suite struct PortsTextTests {
    private func row(
        _ state: ForwardState, local: Int? = 5173, to destination: ForwardDestination = .localhost
    )
        -> ForwardRow
    {
        ForwardRow(
            id: ForwardID(value: 1), kind: .manual, localPort: local, remotePort: 5173,
            destination: destination,
            name: nil, state: state, listening: true, bindNotLoopback: false)
    }

    @Test func anAddressFollowsItsLoopbacks() {
        #expect(row(.active(local: 5174, loopbacks: .both)).localAddress == "localhost:5174")
        #expect(row(.active(local: 5174, loopbacks: .ipv4Only)).localAddress == "127.0.0.1:5174")
        #expect(row(.waiting).localAddress == "localhost:5173")
        #expect(row(.waiting, local: nil).localAddress == nil)
    }

    @Test func onlyAnActiveForwardOpens() {
        #expect(row(.active(local: 5174, loopbacks: .ipv4Only)).url == URL(string: "http://127.0.0.1:5174"))
        #expect(row(.failed(.localPortInUse)).url == nil)
    }

    @Test func theHostItselfIsTheNumberAlone() throws {
        #expect(row(.waiting).shownDestination == "5173")
        let address = try #require(IPLiteral("2001:db8::1"))
        #expect(row(.waiting, to: .address(address)).shownDestination == "[2001:db8::1]:5173")
        let configured = try #require(ForwardDestination(configuredHost: "db"))
        #expect(RemotePort(port: 5432, destination: configured, name: nil).shownDestination == "db:5432")
        #expect(RemotePort(port: 4000, destination: .localhost, name: "ruby").shownDestination == "4000")
    }

    @Test func aMovedForwardSaysWhereItWas() {
        var snapshot = PortsSnapshot()
        snapshot.notices = [
            .listening(port: 3000, name: nil),
            .moved(id: ForwardID(value: 1), remote: 5173, from: 5173, to: 5174),
        ]
        #expect(snapshot.movedFrom(ForwardID(value: 1)) == 5173)
        #expect(snapshot.movedFrom(ForwardID(value: 2)) == nil)
    }

    @Test func aForwardIsFoundByItsID() {
        var snapshot = PortsSnapshot()
        snapshot.forwarded = [row(.waiting)]
        #expect(snapshot.forward(ForwardID(value: 1)) == row(.waiting))
        #expect(snapshot.forward(ForwardID(value: 2)) == nil)
    }
}
