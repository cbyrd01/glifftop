import GliffMachines
import GliffSession
import GliffTransport
import SwiftUI

/// The app's defaults (Settings), stored in `UserDefaults`: the options a new host or machine
/// starts from (`defaultOptions`), and whether the clipboard is shared, passwords included or
/// not.
enum AppSettings {
    /// "focused" or "virtual".
    static let connectScreenKey = "connectScreen"
    /// A `TextSize` factor.
    static let virtualTextSizeKey = "virtualTextSize"
    static let scaleToFitKey = "scaleToFit"
    /// A `VirtualResolution` raw value.
    static let resolutionKey = "virtualResolution"
    /// "Reconnect automatically": on unless turned off.
    static let reconnectsKey = "reconnects"
    /// "Share the clipboard": off until turned on, which asks first.
    static let shareClipboardKey = "shareClipboard"
    /// "Include passwords": a password manager's copies are offered too. Off until turned on,
    /// which asks first.
    static let includePasswordsKey = "includePasswords"
    /// View ▸ Show Status Bar, app-wide; off by default.
    static let showsStatusBarKey = "showsStatusBar"

    /// The options a host not yet saved, or a new machine, starts from.
    static var defaultOptions: MachineOptions {
        let defaults = UserDefaults.standard
        return MachineOptions(
            screen: defaults.string(forKey: connectScreenKey) == "virtual" ? .virtual : .focused,
            textSize: TextSize(rawValue: defaults.double(forKey: virtualTextSizeKey)) ?? .mac,
            resolution: defaults.string(forKey: resolutionKey).flatMap(VirtualResolution.init) ?? .automatic,
            scaleToFit: defaults.bool(forKey: scaleToFitKey),
            reconnects: defaults.object(forKey: reconnectsKey) as? Bool ?? true)
    }
    static var shareClipboard: Bool { UserDefaults.standard.bool(forKey: shareClipboardKey) }
    static var includePasswords: Bool { UserDefaults.standard.bool(forKey: includePasswordsKey) }
}

/// Settings ▸ General: the options each new host or machine starts from, and the clipboard.
struct SettingsView: View {
    @AppStorage(AppSettings.connectScreenKey) private var connectScreen = "focused"
    @AppStorage(AppSettings.virtualTextSizeKey) private var virtualTextSize = TextSize.mac.factor
    @AppStorage(AppSettings.scaleToFitKey) private var scaleToFit = false
    @AppStorage(AppSettings.resolutionKey) private var resolution = VirtualResolution.automatic
    @AppStorage(AppSettings.reconnectsKey) private var reconnects = true
    @AppStorage(AppSettings.shareClipboardKey) private var shareClipboard = false
    @AppStorage(AppSettings.includePasswordsKey) private var includePasswords = false
    @State private var confirmingShare = false
    @State private var confirmingPasswords = false

    var body: some View {
        Form {
            Picker("Screen", selection: $connectScreen) {
                Text(ScreenChoice.focused.label).tag("focused")
                Text(ScreenChoice.virtual.label).tag("virtual")
            }
            // Through TextSize: a stored factor that's no step shows as the one connections use.
            Picker("Virtual screen text size", selection: textSize) {
                ForEach(TextSize.allCases) { Text($0.label()).tag($0) }
            }
            Picker("Virtual screen resolution", selection: $resolution) {
                ForEach(VirtualResolution.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("Scale smaller screens to fit", isOn: $scaleToFit)
            Toggle("Reconnect automatically", isOn: $reconnects)
            Toggle("Share the clipboard", isOn: .askingFirst($shareClipboard, confirming: $confirmingShare))
            Toggle(
                "Include passwords", isOn: .askingFirst($includePasswords, confirming: $confirmingPasswords)
            )
            .disabled(!shareClipboard)
        }
        .formStyle(.grouped)
        .shareClipboardConfirmation(isPresented: $confirmingShare) { shareClipboard = true }
        .alert("Include passwords?", isPresented: $confirmingPasswords) {
            Button("Cancel", role: .cancel) {}
            Button("Include") { includePasswords = true }
        } message: {
            Text("Copies your password manager marks as concealed will reach the host.")
        }
        .frame(width: 420)
        .fixedSize()
    }

    private var textSize: Binding<TextSize> {
        Binding(
            get: { TextSize(rawValue: virtualTextSize) ?? .mac },
            set: { virtualTextSize = $0.factor })
    }
}
