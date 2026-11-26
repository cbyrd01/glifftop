import SwiftUI

/// Connection ▸ Show Ports (⌥⌘P): the key window's Ports popover from its toolbar item, or a
/// sheet with the same content while the toolbar isn't shown. Disabled without a session, or
/// while the window shows one of its model's sheets.
struct PortsCommands: View {
    let model: SessionModel?

    var body: some View {
        Button("Show Ports") {
            if let model { Self.show(model) }
        }
        .keyboardShortcut("p", modifiers: [.command, .option])
        .disabled(model?.isActive != true || model?.showsSheet == true)
    }

    /// `model`'s window's Ports popover, or its sheet while the toolbar isn't shown.
    static func show(_ model: SessionModel) {
        let ports = AppPorts.shared.ports(for: model)
        if WindowToolbar.isShown(window: model.tabGroup?.window) {
            ports.showsPopover = true
        } else {
            ports.showsSheet = true
        }
    }
}

extension View {
    /// Show Ports' sheet, for a window whose toolbar isn't shown.
    func portsSheet(_ session: SessionModel) -> some View {
        modifier(PortsSheet(ports: AppPorts.shared.ports(for: session), session: session))
    }
}

private struct PortsSheet: ViewModifier {
    @Bindable var ports: PortsModel
    let session: SessionModel

    func body(content: Content) -> some View {
        // The model's own sheets come first (a sign-in question must show): this one steps
        // aside while one is up.
        let shown = Binding(
            get: { ports.showsSheet && !session.showsSheet }, set: { ports.showsSheet = $0 })
        content.sheet(isPresented: shown) {
            PortsPopover(ports: ports, session: session) { ports.showsSheet = false }
        }
    }
}
