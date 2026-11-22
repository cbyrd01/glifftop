import GliffMachines
import GliffTransport
import SwiftUI

/// The window without a session: "Connect to a host" (a field, Connect, and Options set before
/// the first connection: Settings' defaults, or a saved machine's when the field names one),
/// then the saved machines, and New Machine in the toolbar. Double-click or Return connects to
/// one; its menu has Connect, Edit…, Favourite and Remove.
struct MachinesView: View {
    /// The window's width while it shows the machines.
    static let width: CGFloat = 600
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
        VStack(alignment: .leading, spacing: 20) {
            connectSection
            if model.machines.list.machines.isEmpty {
                Text("Hosts you connect to are kept here, with their options.")
                    .foregroundStyle(.secondary)
            } else {
                machinesSection
            }
        }
        .padding(24)
        .frame(width: Self.width)
        .toolbar {
            ToolbarItem {
                Button("New Machine", systemImage: "plus", action: model.newMachine)
                    .labelStyle(.titleAndIcon)
                    .help("New Machine… (⌘N)")
            }
        }
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

    /// "Connect to a host": the field, Connect, the forms it takes, why it was refused, and
    /// Options in a box.
    private var connectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect to a host")
                .font(.headline)
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
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            Text("host, user@host or ssh://user@host:port")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let refused, refused.target == target {
                Text(refused.message)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            GroupBox {
                DisclosureGroup("Options", isExpanded: $showsOptions) {
                    VStack(alignment: .leading, spacing: 8) {
                        Form {
                            MachineOptionsForm(
                                options: $options, screenList: model.screenList, host: target,
                                getScreens: { model.screenList.list(host: shownTarget()) })
                        }
                        Text(optionsSource)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
                .padding(4)
            }
            .padding(.top, 4)
        }
    }

    /// Where Options came from, and when they're kept.
    private var optionsSource: String {
        if let machine = model.machines.list.machine(for: target) {
            return "Saved with “\(machine.name)”. Changes are kept when it connects."
        }
        return "From Settings. Kept with the machine once it connects."
    }

    private var machinesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Machines")
                .font(.headline)
            List(model.machines.list.machines, selection: $selection) { MachineRow(machine: $0) }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Up to five rows before it scrolls, on the same rounded fill as Options.
                .frame(height: CGFloat(min(model.machines.list.machines.count, 5)) * 50)
                .padding(6)
                .background(.quinary, in: .rect(cornerRadius: 10))
                .contextMenu(forSelectionType: Machine.ID.self) { ids in
                    if let machine = ids.first.flatMap(model.machines.machine(id:)) {
                        Button("Connect") { connect(machine) }
                        Button("Edit…") { model.machineEdit = MachineEdit(machine: machine, isNew: false) }
                        Button(machine.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
                            toggleFavourite(machine)
                        }
                        Divider()
                        Button("Remove…") { removing = machine }
                    }
                } primaryAction: { ids in
                    if let machine = ids.first.flatMap(model.machines.machine(id:)) { connect(machine) }
                }
        }
    }

    /// The field (or Settings) changed: unless edited, Options are the saved machine's the
    /// field names, else Settings'. A list for another host goes, and a monitor listed for
    /// another host can't stay chosen, edited or not: only the host's list or its machine's
    /// own screen keeps one.
    private func fillOptions(for host: String) {
        model.screenList.forget(unless: host)
        let saved = model.machines.list.machine(for: host)?.options
        if options == filled {
            filled = saved ?? AppSettings.defaultOptions
            if options != filled { options = filled }
        }
        if !model.screenList.allows(options.screen, host: host), options.screen != saved?.screen {
            options.screen = (saved ?? AppSettings.defaultOptions).screen
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

    private func toggleFavourite(_ machine: Machine) {
        var changed = machine
        changed.isFavorite.toggle()
        model.machines.save(changed)
    }
}

/// A saved machine in the list: a display, its name (starred when a favourite), its host and
/// screen, and when it last connected.
private struct MachineRow: View {
    let machine: Machine

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(machine.name)
                        .fontWeight(.semibold)
                    if machine.isFavorite {
                        Image(systemName: "star.fill")
                            .imageScale(.small)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favourite")
                    }
                }
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
        }
        .padding(.vertical, 4)
    }
}
