import GliffMachines
import GliffTransport
import SwiftUI

/// The window without a session: "Connect to a host" (a field, Connect, and Options set before
/// the first connection: Settings' defaults, or a saved machine's when the field names one),
/// then the saved machines. Double-click or Return connects to one; its menu has Connect, Edit…,
/// Favourite and Remove.
struct MachinesView: View {
    let model: SessionModel
    @AppStorage("lastTarget") private var target = ""
    @State private var options = AppSettings.defaultOptions
    /// What Options were last filled with (Settings', or the saved machine's the field names):
    /// while `options` still equal them, they follow the field and Settings; once edited, they
    /// stay as edited.
    @State private var filled = AppSettings.defaultOptions
    @State private var showsOptions = false
    @State private var selection: Machine.ID?
    @State private var removing: Machine?
    /// The host Connect refused, and why: shown while the field holds that host (an edit hides
    /// it, undoing the edit shows it again), so committing composed text on Connect can't clear it.
    @State private var refused: (target: String, message: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to a host")
                .font(.title2)
            HStack {
                // A host, not a login: no "user" or "@" in the prompt and a URL's content type,
                // so AutoFill and password managers don't take it for a username field; no
                // Writing Tools or autocorrection either, which could hold the typing in a panel.
                TextField("Host", text: $target, prompt: Text("ssh host"))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .writingToolsBehavior(.disabled)
                    .labelsHidden()
                    .onChange(of: target) { fillOptions(for: target) }
                    // Return here, not as the window's default button: Return in the list
                    // connects to the selected machine.
                    .onSubmit(connect)
                Button("Connect", action: connect)
            }
            Text("host, user@host or ssh://user@host:port")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let refused, refused.target == target {
                Text(refused.message)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            DisclosureGroup("Options", isExpanded: $showsOptions) {
                Form {
                    MachineOptionsForm(
                        options: $options, screenList: model.screenList, host: target,
                        getScreens: { model.screenList.list(host: shownTarget()) })
                }
                .padding(.top, 4)
            }
            if !model.machines.list.machines.isEmpty {
                machineList
            }
            HStack {
                Button("New Machine…", systemImage: "plus", action: model.newMachine)
                    .labelStyle(.iconOnly)
                    .help("New Machine…")
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { fillOptions(for: target) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            fillOptions(for: target)
        }
        .alert(
            "Remove “\(removing?.name ?? "")”?",
            isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let removing { model.machines.remove(id: removing.id) }
            }
        } message: {
            Text("Its options are forgotten. Connecting to its host again adds it back.")
        }
    }

    private var machineList: some View {
        List(model.machines.list.machines, selection: $selection) { machine in
            MachineRow(machine: machine) { favourite(machine, !machine.isFavorite) }
        }
        .frame(height: 220)
        .contextMenu(forSelectionType: Machine.ID.self) { ids in
            if let machine = ids.first.flatMap(model.machines.machine(id:)) {
                Button("Connect") { connect(machine) }
                Button("Edit…") { model.machineEdit = MachineEdit(machine: machine, isNew: false) }
                Button(machine.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
                    favourite(machine, !machine.isFavorite)
                }
                Divider()
                Button("Remove…") { removing = machine }
            }
        } primaryAction: { ids in
            if let machine = ids.first.flatMap(model.machines.machine(id:)) { connect(machine) }
        }
    }

    /// The field (or Settings) changed: unless edited, Options are the saved machine's the
    /// field names, else Settings'. A list for another host goes, and a monitor listed for
    /// another host can't stay chosen, edited or not.
    private func fillOptions(for host: String) {
        model.screenList.forget(unless: host)
        if options == filled {
            filled = model.machines.list.machine(for: host)?.options ?? AppSettings.defaultOptions
            if options != filled { options = filled }
        }
        if !model.screenList.allows(options.screen, host: host), model.machines.list.machine(for: host) == nil
        {
            options.screen = AppSettings.defaultOptions.screen
        }
    }

    /// The host the field shows. Text it holds but its value may lack (still composing, or
    /// put there by AutoFill) is committed first; a list for another host is forgotten now, not
    /// after this action.
    private func shownTarget() -> String {
        let shown = TextComposition.commit() ?? target
        if target != shown { target = shown }
        model.screenList.forget(unless: shown)
        return shown
    }

    private func connect() {
        // What the refused host is compared with.
        let shown = shownTarget()
        fillOptions(for: shown)
        do {
            try model.connect(to: shown, options: options)
        } catch {
            refused = (shown, error.message)
        }
    }

    private func connect(_ machine: Machine) {
        do {
            try model.connect(to: machine.destination, options: machine.options)
        } catch {
            target = machine.destination
            refused = (machine.destination, error.message)
        }
    }

    private func favourite(_ machine: Machine, _ isFavorite: Bool) {
        var changed = machine
        changed.isFavorite = isFavorite
        model.machines.save(changed)
    }
}

/// A saved machine in the list: its name, its host and screen, when it last connected, and a
/// star that makes it a favourite.
private struct MachineRow: View {
    let machine: Machine
    let toggleFavourite: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                Text("\(machine.destination) · \(machine.options.screen.label)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let lastConnected = machine.lastConnected {
                Text(lastConnected, format: .relative(presentation: .named))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button(
                machine.isFavorite ? "Remove from Favourites" : "Add to Favourites",
                systemImage: machine.isFavorite ? "star.fill" : "star", action: toggleFavourite
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(machine.isFavorite ? .yellow : .secondary)
        }
        .padding(.vertical, 2)
    }
}
