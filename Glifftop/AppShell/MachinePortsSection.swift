import GliffMachines
import GliffPorts
import SwiftUI

/// The machine's "Ports forwarded when connected", with Edit… for the list: each with a
/// remove button, and a field to add a port on the host.
struct MachinePortsSection: View {
    @Binding var options: MachineOptions
    let host: String
    @State private var editing = false
    @State private var typed = ""

    var body: some View {
        LabeledContent("Ports forwarded when connected") {
            HStack {
                Text(summary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button(editing ? "Done" : "Edit…") { editing.toggle() }
            }
        }
        if editing {
            ForEach(options.forwards, id: \.self) { forward in
                HStack {
                    Text(forward.shownDestination)
                        .monospacedDigit()
                    if let local = forward.localPort {
                        Text("on this Mac's port \(String(local))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") {
                        options.forwards.removeAll { $0 == forward }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            HStack {
                TextField(host.isEmpty ? "Port on the host" : "Port on \(host)", text: $typed)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(!canAdd)
            }
            // Return adds the typed port, not the sheet's Save.
            .preference(key: PendingEntryKey.self, value: !typed.isEmpty)
        }
    }

    private var summary: String {
        options.forwards.isEmpty
            ? "None"
            : options.forwards.map(\.shownDestination).joined(separator: ", ")
    }

    private var canAdd: Bool {
        options.forwardToAdd(typed) != nil
    }

    private func add() {
        if options.addForwardWhenConnected(typed) { typed = "" }
    }
}

extension SavedForward {
    /// As the Ports popover's rows show a destination.
    fileprivate var shownDestination: String { forwardDestination.shown(remotePort) }
}
