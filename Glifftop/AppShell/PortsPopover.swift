import GliffPorts
import GliffTransport
import SwiftUI

/// The window's host's ports (all its windows share them): Forwarded, Available, From ssh
/// config and the other ports, then Forward a Port… and "Forward new ports automatically".
/// `done` adds a Done button, for the sheet.
struct PortsPopover: View {
    @Bindable var ports: PortsModel
    let session: SessionModel
    var done: (() -> Void)?

    @Bindable private var app = AppPorts.shared
    @State private var adding = false
    @State private var remoteText = ""
    @State private var localText = ""

    private var host: String { session.host }
    private var snapshot: PortsSnapshot { ports.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ports on \(host)")
                .font(.headline)
            if let detection = detectionText {
                Text(detection)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .vertical) {
                sections
                ScrollView { sections }
            }
            .frame(maxHeight: 420)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 460)
        .onAppear(perform: ports.markSeen)
        .onChange(of: snapshot.available) { ports.markSeen() }
    }

    private var detectionText: String? {
        switch snapshot.detection {
        case .running, .idle: nil
        case .unavailable: "Detecting ports isn't available on \(host)"
        case .waitingForPlace: "Detecting ports waits for a free ssh channel on \(host)"
        case .stopped: "Port detection stopped"
        }
    }

    private var sections: some View {
        let made = snapshot.forwarded.filter { $0.kind != .config }
        let configured = snapshot.forwarded.filter { $0.kind == .config }
        return VStack(alignment: .leading, spacing: 12) {
            if snapshot.detection == .running, snapshot.forwarded.isEmpty, snapshot.available.isEmpty,
                snapshot.other.isEmpty, snapshot.notApplied.isEmpty
            {
                Text("No ports are listening on \(host). Start a server there, or forward a port by number.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !made.isEmpty {
                section("Forwarded") { ForEach(made) { row($0) } }
            }
            if !snapshot.available.isEmpty {
                section("Available") { ForEach(snapshot.available, id: \.self) { remote($0) } }
            }
            if !configured.isEmpty || !snapshot.notApplied.isEmpty {
                section("From ssh config") {
                    ForEach(configured) { row($0) }
                    ForEach(Array(snapshot.notApplied.enumerated()), id: \.offset) { notApplied($0.element) }
                }
            }
            if !snapshot.other.isEmpty {
                RowDisclosureGroup("Other ports (\(snapshot.other.count))") {
                    ForEach(snapshot.other, id: \.self) { remote($0) }
                }
            }
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            rows()
        }
    }

    private func row(_ row: ForwardRow) -> some View {
        PortsForwardRow(
            row: row, detecting: snapshot.detection == .running, movedFrom: snapshot.movedFrom(row.id),
            ports: ports, session: session)
    }

    /// An Available or other port: its number, its name, and Forward.
    private func remote(_ port: RemotePort) -> some View {
        HStack(spacing: 8) {
            Text(port.shownDestination)
                .monospacedDigit()
            if let name = port.name {
                Text(name).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Forward") { ports.forward(port) }
        }
    }

    private func notApplied(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(SignInQuestion.shownHostText(line))
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(
                NotAppliedReason(line: line) == .privilegedPort
                    ? "Ports under 1024 aren't forwarded" : "Not applied by Glifftop"
            )
            .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Button("Forward a Port…") { adding.toggle() }
            Spacer()
            Toggle("Forward new ports automatically", isOn: $app.automatic)
                .toggleStyle(.checkbox)
        }
        if adding {
            HStack {
                TextField("Port on \(host)", text: $remoteText)
                TextField("Local port", text: $localText)
                    .frame(width: 100)
                Button("Forward", action: forwardTyped)
                    .disabled(typed == nil)
            }
            .onSubmit(forwardTyped)
        }
        if let done {
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The typed ports: one on the host, and a Mac port or none for the chooser's.
    private var typed: (remote: Int, local: Int?)? {
        guard let remote = Int(remoteText.trimmingCharacters(in: .whitespaces)), 1...65535 ~= remote
        else { return nil }
        let local = localText.trimmingCharacters(in: .whitespaces)
        if local.isEmpty { return (remote, nil) }
        guard let port = Int(local), PortForward.localPorts ~= port else { return nil }
        return (remote, port)
    }

    private func forwardTyped() {
        guard let typed else { return }
        ports.forward(remote: typed.remote, localPort: typed.local)
        (remoteText, localText, adding) = ("", "", false)
    }
}
