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
        LabeledContent {
            HStack {
                Text(summary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button(editing ? "Done" : "Edit…", action: toggleEditing)
            }
        } label: {
            // Wrapped, so the form's label column stays as narrow as its other labels.
            Text("Ports forwarded when connected")
                .frame(maxWidth: 120, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        if editing {
            ForEach(options.forwards, id: \.self) { forward in
                HStack {
                    // The Mac port on a line of its own: a long address fits.
                    VStack(alignment: .leading) {
                        Text(forward.shownDestination)
                            .monospacedDigit()
                        if let local = forward.localPort {
                            Text("on this Mac's port \(String(local))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
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
                // Return adds a typed port; with none, it is the sheet's Save.
                Button("Add", action: add)
                    .defaultAction(when: !pending.isEmpty)
                    .disabled(!canAdd)
            }
            .preference(key: PendingEntryKey.self, value: pending)
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        options.forwards.isEmpty
            ? "None"
            : options.forwards.map(\.shownDestination).joined(separator: ", ")
    }

    /// The typed text Return adds: none for a port in the list, which Save keeps as it is.
    private var pending: String {
        if case .kept = options.typedPort(typed) { return "" }
        return typed.trimmingCharacters(in: .whitespaces)
    }

    private var canAdd: Bool {
        if case .new = options.typedPort(typed) { true } else { false }
    }

    /// Why the typed text can't be added, if it can't.
    private var problem: String? {
        switch options.typedPort(typed) {
        case .notAPort: "A port is 1 to 65535."
        case .kept: "This port is in the list."
        case .empty, .new: nil
        }
    }

    private func add() {
        if options.addForwardWhenConnected(typed) { typed = "" }
    }

    /// Done adds a port still typed, and lets go of the field.
    private func toggleEditing() {
        if editing {
            add()
            typed = ""
        }
        editing.toggle()
    }
}

extension SavedForward {
    /// As the Ports popover's rows show a destination.
    fileprivate var shownDestination: String { forwardDestination.shown(remotePort) }
}
