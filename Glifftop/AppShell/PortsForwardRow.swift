import GliffMachines
import GliffPorts
import GliffTransport
import SwiftUI

/// One forward in the Ports popover: its Mac address, where it goes on the host and what
/// listens there, its state, Open or Try Again, and its menu (Open in Browser, Copy Address,
/// Forward When Connected, Stop).
struct PortsForwardRow: View {
    let row: ForwardRow
    /// The host's ports are being followed: a forward not seen listening is said so.
    let detecting: Bool
    let movedFrom: Int?
    let ports: PortsModel
    let session: SessionModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                // A forward with no Mac port yet (waiting since it was made) shows the host's
                // side alone.
                if let address = row.localAddress {
                    Text(address)
                        .monospacedDigit()
                    Image(systemName: "arrow.right")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("to")
                }
                Text(row.shownDestination)
                    .monospacedDigit()
                if let name = row.name {
                    Text(name).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                actions
            }
            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What the row says of its state, under it.
    private var notes: [String] {
        var notes: [String] = []
        switch row.state {
        case .active:
            if detecting, row.destination.isLoopback, !row.listening {
                notes.append("Not listening on \(session.host)")
            }
        case .waiting: notes.append("Waiting for the connection…")
        case .failed(.localPortInUse):
            notes.append(
                row.localPort.map { "Port \($0) is in use on this Mac" } ?? "The port is in use on this Mac")
        case .failed(.failed): notes.append("ssh didn't add the forward")
        case .stopping: notes.append("Stopping…")
        }
        if let movedFrom { notes.append("\(movedFrom) was in use on this Mac") }
        if row.bindNotLoopback { notes.append("Bound on this Mac's loopback only") }
        return notes
    }

    @ViewBuilder private var actions: some View {
        if let url = row.url {
            Button("Open") { openURL(url) }
        } else if case .failed = row.state {
            Button("Try Again") { ports.retry(row) }
        }
        Menu {
            if let url = row.url {
                Button("Open in Browser") { openURL(url) }
            }
            if let address = row.localAddress {
                Button("Copy Address") { TextPasteboard.copy(address) }
            }
            if row.kind != .config {
                Toggle(
                    "Forward When Connected",
                    isOn: Binding(
                        get: {
                            session.machine?.options.forwardsWhenConnected(row.destination, row.remotePort)
                                == true
                        },
                        set: { _ in
                            session.updateMachine {
                                $0.toggleForwardWhenConnected(
                                    row.destination, row.remotePort, localPort: row.localPort)
                            }
                        })
                )
                .disabled(session.machine == nil)
                .help(session.machine == nil ? "Save \(session.host) as a machine to keep its ports" : "")
            }
            Divider()
            Button("Stop") { ports.stop(row) }
                .disabled(row.state == .stopping)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("More")
    }
}
