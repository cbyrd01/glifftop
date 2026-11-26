import GliffClipboard
import GliffMachines
import GliffSession
import GliffTransport
import SwiftUI

/// A machine's options, for the connect field's Options and the machine sheet: the screen (the
/// host's monitors once Get Screens lists them; a machine's monitor though not listed), a
/// virtual screen's text size and resolution, Scale to Fit, reconnect, the clipboard, and, in
/// the sheet alone, the ports forwarded when connected (the connect field's are its machine's).
struct MachineOptionsForm: View {
    @Binding var options: MachineOptions
    let screenList: ScreenList
    /// The host as its field shows it: the list shown is this host's.
    let host: String
    let getScreens: () -> Void
    /// The machine sheet's: whether its saved ports are shown.
    var showsPorts = false
    /// Settings' sharing, which Same as Settings follows.
    @StoredClipboardSharing private var settingsSharing
    @State private var askingClipboard: ClipboardQuestion?
    /// The choice the question is about, set when it is asked.
    @State private var askedClipboard: ClipboardSharing?

    var body: some View {
        HStack {
            Picker("Screen", selection: $options.screen) {
                Text(ScreenChoice.focused.label).tag(ScreenChoice.focused)
                Text(ScreenChoice.virtual.label).tag(ScreenChoice.virtual)
                if !monitors.isEmpty {
                    Divider()
                    ForEach(monitors, id: \.self) { Text(screenList.label(for: $0, host: host)).tag($0) }
                }
            }
            // As wide as its labels, up to a cap: a longer one is shortened, and whole on hover.
            .frame(maxWidth: 320)
            .fixedSize()
            .help(screenList.label(for: options.screen, host: host, full: true))
            // A monitor a new list for this host leaves out is gone: it can't stay chosen.
            .onChange(of: screenList.screens) {
                if screenList.isFor(host), !screenList.allows(options.screen, host: host) {
                    options.screen = .focused
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
        Picker("Clipboard", selection: clipboard) {
            Text("Same as Settings (\(settingsSharing.label))").tag(ClipboardSharing?.none)
            Divider()
            ForEach(ClipboardSharing.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        .clipboardSharingConfirmation($askingClipboard) { _ in options.clipboard = askedClipboard }
        if showsPorts { MachinePortsSection(options: $options, host: host) }
    }

    /// The machine's sharing, asking first when the choice sends more than the sharing it has
    /// now (Same as Settings sends what Settings' does).
    private var clipboard: Binding<ClipboardSharing?> {
        Binding(
            get: { options.clipboard },
            set: { choice in
                let (from, to) = (options.clipboard ?? settingsSharing, choice ?? settingsSharing)
                if from.sendsLess(than: to) {
                    askedClipboard = choice
                    askingClipboard = ClipboardQuestion(level: to, from: from)
                } else {
                    options.clipboard = choice
                }
            })
    }

    /// The host's listed monitors, and the chosen one though not listed.
    private var monitors: [ScreenChoice] {
        let listed = screenList.isFor(host) ? screenList.screens.map { ScreenChoice.named($0.name) } : []
        if case .named = options.screen, !listed.contains(options.screen) { return [options.screen] + listed }
        return listed
    }
}
