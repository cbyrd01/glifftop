import SwiftUI

/// The toolbar's Ports item: the `network` symbol, a badge counting the forwards listening on
/// this Mac, else a dot while an offer is unseen, and the Ports popover.
struct PortsToolbarItem: View {
    let model: SessionModel

    var body: some View {
        PortsButton(ports: AppPorts.shared.ports(for: model), session: model)
    }
}

private struct PortsButton: View {
    @Bindable var ports: PortsModel
    let session: SessionModel

    var body: some View {
        Button {
            ports.showsPopover.toggle()
        } label: {
            Image(systemName: "network")
                .overlay(alignment: .topTrailing) { badge }
        }
        .help("Ports on \(session.host)")
        .accessibilityLabel("Ports")
        .accessibilityValue(ports.activeCount == 0 ? "" : "\(ports.activeCount) forwarded")
        .popover(isPresented: $ports.showsPopover, arrowEdge: .bottom) {
            PortsPopover(ports: ports, session: session)
                .onAppear { ports.popoverShown = true }
                .onDisappear { ports.popoverShown = false }
        }
    }

    @ViewBuilder private var badge: some View {
        if ports.activeCount > 0 {
            Text("\(ports.activeCount)")
                .font(.system(size: 9, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 12, minHeight: 12)
                .background(.blue, in: .capsule)
                .offset(x: 7, y: -5)
        } else if ports.hasUnseenOffer {
            Circle()
                .fill(.blue)
                .frame(width: 6, height: 6)
                .offset(x: 3, y: -2)
        }
    }
}
