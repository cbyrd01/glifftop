import GliffMachines
import GliffSession
import GliffTransport
import SwiftUI

/// A machine in the sheet: an existing one (Edit…, Connection ▸ Edit Machine…) or a new one
/// (New Machine…, the + button).
struct MachineEdit: Identifiable {
    let id = UUID()
    var machine: Machine
    let isNew: Bool
}

/// The machine sheet: its name, host and options. Save keeps it; a new one can Connect too.
struct EditMachineView: View {
    let model: SessionModel
    @State var machine: Machine
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    /// The host Save refused, and why: shown while the field holds that host.
    @State private var refused: (host: String, message: String)?
    /// The sheet's own list of the host's monitors: the session's (View ▸ Screen) is left alone.
    @State private var screenList = ScreenList()

    private enum Field { case name, host }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Machine" : "Edit Machine")
                .font(.title2)
            Form {
                TextField("Name", text: $machine.name, prompt: Text(machine.destination))
                    .focused($focus, equals: .name)
                // As the connect field: a host, not a login.
                TextField("Host", text: $machine.destination, prompt: Text("ssh host"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .writingToolsBehavior(.disabled)
                    .focused($focus, equals: .host)
                    // The running session's machine keeps its host: its reconnects and its
                    // record follow it.
                    .disabled(isSessionMachine)
                    .help(isSessionMachine ? hostLockedHelp : "")
                    .onChange(of: machine.destination) {
                        screenList.forget(unless: machine.destination)
                        // A monitor is another host's once the host changes.
                        if case .named = machine.options.screen { machine.options.screen = .focused }
                    }
                if let refused, refused.host == machine.destination {
                    Text(refused.message)
                        .foregroundStyle(.red)
                        .font(.callout)
                } else if let other {
                    Text("“\(other.name)” has this host: saving replaces it.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                MachineOptionsForm(
                    options: $machine.options, screenList: screenList, host: machine.destination,
                    getScreens: { screenList.list(host: committed().destination) })
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if isNew {
                    Button("Connect") { if let saved = save() { connect(saved) } }
                }
                Button("Save") { _ = save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { screenList.stop() }
    }

    /// Whether it's the machine of the window's session, running or ended: the window finds its
    /// machine by host, so the host can't change until the session is closed.
    private var isSessionMachine: Bool { !isNew && model.machine?.id == machine.id }

    private var hostLockedHelp: String {
        model.canDisconnect ? "Disconnect to change the host" : "Close the session to change the host"
    }

    /// Another machine with the host typed: saving this one replaces it.
    private var other: Machine? {
        guard let found = model.machines.list.machine(for: machine.destination), found.id != machine.id
        else { return nil }
        return found
    }

    /// The machine as its fields show it, text still being composed included.
    private func committed() -> Machine {
        if let text = TextComposition.commit() {
            switch focus {
            case .name: machine.name = text
            case .host: machine.destination = text
            case nil: break
            }
        }
        return machine
    }

    /// Keeps the machine if its host is a valid ssh destination (an empty name becomes the
    /// host), and closes the sheet; else says why.
    private func save() -> Machine? {
        var saved = committed()
        do throws(SSHTargetError) {
            saved.destination = try SSHTarget(saved.destination).value
        } catch {
            refused = (saved.destination, error.message)
            return nil
        }
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if saved.name.isEmpty { saved.name = saved.destination }
        model.machines.saveEdit(saved)
        model.machineSaved(saved)
        dismiss()
        return saved
    }

    private func connect(_ saved: Machine) {
        try? model.connect(to: saved.destination, options: saved.options)
    }
}
