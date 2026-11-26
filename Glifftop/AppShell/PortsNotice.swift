import GliffPorts
import GliffTransport
import SwiftUI

/// The status bar's part of the window's port notices: the newest one, with its buttons and
/// Dismiss, until it is answered.
struct PortsNoticeBar: View {
    let session: SessionModel

    var body: some View {
        let ports = AppPorts.shared.ports(for: session)
        if let notice = ports.notice {
            PortsNoticeContent(notice: notice, ports: ports, session: session)
                .controlSize(.small)
        }
    }
}

/// A new notice as a glass capsule over the bottom edge of the picture, for 8 s after it
/// comes, while the status bar is hidden (it shows notices itself). Glass on the capsule only,
/// never on the video under it.
struct PortsNoticeCapsule: View {
    let session: SessionModel
    let statusBarShown: Bool

    var body: some View {
        let ports = AppPorts.shared.ports(for: session)
        ZStack {
            if !statusBarShown, let notice = ports.fresh {
                PortsNoticeContent(notice: notice, ports: ports, session: session)
                    .overPictureCapsule()
                    // Clicks go to the host while input is captured.
                    .allowsHitTesting(!session.capture.isCaptured)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: ports.fresh)
    }
}

/// A notice's sentence and its buttons:
/// - "Port 5173 is listening on omarchy (node)" [Forward] [Ignore];
/// - "3 ports are listening on omarchy" [Show Ports];
/// - "Port 5173 is forwarded to localhost:5173" [Open] [Stop];
/// - "Port 5173 is now forwarded to localhost:5174" [Open].
private struct PortsNoticeContent: View {
    let notice: PortNotice
    let ports: PortsModel
    let session: SessionModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(sentence)
                .lineLimit(1)
            buttons
            Button("Dismiss", systemImage: "xmark") { ports.dismiss(notice) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
    }

    private var host: String { session.host }

    private var sentence: String {
        switch notice {
        case .listening(let port, let name):
            "Port \(port) is listening on \(host)" + (name.map { " (\($0))" } ?? "")
        case .several(let ports): "\(ports.count) ports are listening on \(host)"
        case .forwarded(let id, let remote, let local):
            "Port \(remote) is forwarded to \(address(id, local))"
        case .moved(let id, let remote, _, let to):
            "Port \(remote) is now forwarded to \(address(id, to))"
        }
    }

    @ViewBuilder private var buttons: some View {
        switch notice {
        case .listening(let port, _):
            Button("Forward") { ports.forwardOffer(port) }
            Button("Ignore") { ports.ignore(port) }
        case .several:
            Button("Show Ports") {
                PortsCommands.show(session)
                ports.dismiss(notice)
            }
        case .forwarded(let id, _, _):
            open(id)
            Button("Stop") { ports.stop(id) }
        case .moved(let id, _, _, _):
            open(id)
        }
    }

    /// Open: the forward's page, and the notice is answered.
    private func open(_ id: ForwardID) -> some View {
        let url = ports.snapshot.forward(id)?.url
        return Button("Open") {
            guard let url else { return }
            openURL(url)
            ports.dismiss(notice)
        }
        .disabled(url == nil)
    }

    /// Where forward `id` listens now, else on `local` on both loopbacks.
    private func address(_ id: ForwardID, _ local: Int) -> String {
        ports.snapshot.forward(id)?.localAddress ?? Loopbacks.both.address(local)
    }
}
