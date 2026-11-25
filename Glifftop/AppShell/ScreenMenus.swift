import GliffMachines
import GliffSession
import GliffTransport
import SwiftUI

/// View ▸ Text Size: the window's text size on a virtual screen, the one in use
/// checked; a step that gives the same remote scale as a larger one on this display is off.
struct TextSizeMenu: View {
    @Bindable var model: SessionModel
    /// Room either side of its title, inside the control (the toolbar's).
    var labelPadding: CGFloat = 0

    var body: some View {
        Menu {
            Picker("Text Size", selection: $model.textSize) {
                ForEach(TextSize.allCases) { size in
                    Text(size.label(backingScale: model.backingScale))
                        .tag(size)
                        // The one in use stays enabled, so it never shows checked but off.
                        .disabled(
                            size != model.textSize && (model.backingScale.map(size.changesNothing) ?? false))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text("Text Size").padding(.horizontal, labelPadding)
        }
        // A mirror's scale is the monitor's own.
        .disabled(!model.isVirtual)
    }
}

/// View ▸ Resolution: a virtual screen's, the one in use checked; Standard is off on a display
/// under 2×, where it would change nothing.
struct ResolutionMenu: View {
    @Bindable var model: SessionModel

    var body: some View {
        Menu("Resolution") {
            Picker("Resolution", selection: $model.resolution) {
                ForEach(VirtualResolution.allCases, id: \.self) { resolution in
                    Text(resolution.label)
                        .tag(resolution)
                        // The one in use stays enabled, so it never shows checked but off.
                        .disabled(
                            resolution == .standard && model.resolution != .standard
                                && (model.backingScale ?? 2) < 2)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        // A mirror's pixels are the monitor's own.
        .disabled(!model.isVirtual)
    }
}

/// View ▸ Screen: what the session shows, the one in use checked; another starts a
/// new session to the same host. The host's monitors appear once listed.
struct ScreenMenu: View {
    let model: SessionModel
    /// Room either side of its title, inside the control (the toolbar's).
    var labelPadding: CGFloat = 0

    var body: some View {
        Menu {
            Picker("Screen", selection: Binding(get: { model.screenChoice }, set: model.switchScreen)) {
                Text(focusedLabel).tag(ScreenChoice.focused)
                Text(ScreenChoice.virtual.label).tag(ScreenChoice.virtual)
                if !named.isEmpty {
                    Divider()
                    ForEach(named, id: \.self) {
                        Text(model.screenList.label(for: $0, host: model.host)).tag($0)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            // While streaming only: during connecting the session's own ssh may still be
            // waiting for approval, and a second would ask beside it.
            Button("Refresh Screen List") { model.screenList.list(host: model.host) }
                .disabled(model.screenList.isListing || !model.hasPicture)
            if let error = model.screenList.error, model.screenList.isFor(model.host) {
                Text(error)
            }
        } label: {
            Text("Screen").padding(.horizontal, labelPadding)
        }
        .disabled(model.destination == nil)
    }

    /// "Focused Monitor (DP-2)" once a session on it names its output.
    private var focusedLabel: String {
        // A name as a monitor's must be: no empty or odd text in the menu.
        guard model.screenChoice == .focused,
            let output = MonitorPlanning.monitor(shownBy: .focused, output: model.outputName)
        else {
            return ScreenChoice.focused.label
        }
        return "\(ScreenChoice.focused.label) (\(output))"
    }

    /// The listed monitors (if listed for this host), and a monitor in use though not listed,
    /// so the one in use is always there to be checked.
    private var named: [ScreenChoice] {
        let listed =
            model.screenList.isFor(model.host)
            ? model.screenList.screens.map { ScreenChoice.named($0.name) } : []
        if case .named = model.screenChoice, !listed.contains(model.screenChoice) {
            return [model.screenChoice] + listed
        }
        return listed
    }
}
