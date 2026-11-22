import GliffMachines
import GliffSession
import GliffTransport
import SwiftUI

/// A machine's options, for the connect field's Options and the machine sheet: the screen (the
/// host's monitors once Get Screens lists them; a machine's monitor though not listed), a
/// virtual screen's text size and resolution, Scale to Fit, and reconnect.
struct MachineOptionsForm: View {
    @Binding var options: MachineOptions
    let screenList: ScreenList
    /// The host as its field shows it: the list shown is this host's.
    let host: String
    let getScreens: () -> Void

    var body: some View {
        HStack {
            Picker("Screen", selection: $options.screen) {
                Text(ScreenChoice.focused.label).tag(ScreenChoice.focused)
                Text(ScreenChoice.virtual.label).tag(ScreenChoice.virtual)
                if !monitors.isEmpty {
                    Divider()
                    ForEach(monitors, id: \.self) { Text(label(for: $0)).tag($0) }
                }
            }
            Button("Get Screens", action: getScreens)
                .disabled(screenList.isListing)
            if screenList.isListing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        if let error = screenList.error, screenList.isFor(host) {
            Text(error)
                .foregroundStyle(.red)
                .font(.callout)
        }
        if options.screen == .virtual {
            Picker("Text size", selection: $options.textSize) {
                ForEach(TextSize.allCases) { Text($0.label()).tag($0) }
            }
            Picker("Resolution", selection: $options.resolution) {
                ForEach(VirtualResolution.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
        Toggle("Scale smaller screens to fit", isOn: $options.scaleToFit)
        Toggle("Reconnect automatically", isOn: $options.reconnects)
    }

    /// The host's listed monitors, and the chosen one though not listed.
    private var monitors: [ScreenChoice] {
        let listed = screenList.isFor(host) ? screenList.screens.map { ScreenChoice.named($0.name) } : []
        if case .named = options.screen, !listed.contains(options.screen) { return [options.screen] + listed }
        return listed
    }

    private func label(for choice: ScreenChoice) -> String {
        guard case .named(let name) = choice, screenList.isFor(host),
            let listed = screenList.screens.first(where: { $0.name == name })
        else { return choice.label }
        return listed.label
    }
}
