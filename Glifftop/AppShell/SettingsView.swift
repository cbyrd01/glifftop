import GliffClipboard
import GliffInput
import GliffMachines
import GliffSession
import GliffTransport
import SwiftUI

/// The app's defaults (Settings), stored in `UserDefaults`: the options a new host or machine
/// starts from (`defaultOptions`), whether the clipboard is shared, passwords included or not,
/// and the input mode a new window starts in.
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
    /// Whether the clipboard is shared (`ClipboardSharing`): off until turned on, which asks
    /// first.
    static let shareClipboardKey = "shareClipboard"
    /// Whether a password manager's copies are shared too (`ClipboardSharing.withPasswords`):
    /// off until turned on, which asks first; turning sharing off clears it.
    static let includePasswordsKey = "includePasswords"
    /// View ▸ Show Status Bar, app-wide; off by default.
    static let showsStatusBarKey = "showsStatusBar"
    /// The input mode a new window starts in (`CaptureMode.stored`); Integrated by default.
    static let inputModeKey = "inputMode"
    /// Show All Monitors ▸ Show as Windows puts the windows on the Mac's displays in the host's
    /// order (`MonitorPlacement`); off by default. An app setting: it depends on this Mac's
    /// displays.
    static let placeMonitorWindowsKey = "placeMonitorWindows"

    /// Settings' input mode, which each new window starts in.
    static var inputMode: CaptureMode {
        CaptureMode(stored: UserDefaults.standard.string(forKey: inputModeKey))
    }

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
    static var placesMonitorWindows: Bool { UserDefaults.standard.bool(forKey: placeMonitorWindowsKey) }
    /// Settings' Share the clipboard, which a machine with no setting of its own follows.
    static var clipboardSharing: ClipboardSharing {
        let defaults = UserDefaults.standard
        return ClipboardSharing(
            share: defaults.bool(forKey: shareClipboardKey),
            includePasswords: defaults.bool(forKey: includePasswordsKey))
    }
}

/// Settings ▸ General: the options each new host or machine starts from, the clipboard, and
/// the input mode, and where Show as Windows puts its windows.
struct SettingsView: View {
    @AppStorage(AppSettings.connectScreenKey) private var connectScreen = "focused"
    @AppStorage(AppSettings.virtualTextSizeKey) private var virtualTextSize = TextSize.mac.factor
    @AppStorage(AppSettings.scaleToFitKey) private var scaleToFit = false
    @AppStorage(AppSettings.resolutionKey) private var resolution = VirtualResolution.automatic
    @AppStorage(AppSettings.reconnectsKey) private var reconnects = true
    @AppStorage(AppSettings.inputModeKey) private var inputMode = CaptureMode.integrated.stored
    @AppStorage(AppSettings.placeMonitorWindowsKey) private var placeMonitorWindows = false
    @StoredClipboardSharing private var clipboardSharing
    @State private var askingClipboard: ClipboardQuestion?

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
            Picker("Clipboard", selection: .askingFirst($clipboardSharing, asking: $askingClipboard)) {
                ForEach(ClipboardSharing.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("A machine with its own Clipboard setting keeps it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            // Through `CaptureMode(stored:)`: a stored value that's neither shows as Integrated.
            Picker("Input", selection: mode) {
                ForEach(CaptureMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text(
                "Integrated: the pointer moves freely; over the toolbar ⌘ shortcuts are the Mac's. "
                    + "Capture: the pointer stays in the picture until Shift+Esc."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Toggle("Place monitor windows in the host's order", isOn: $placeMonitorWindows)
            Text(
                "Show All Monitors ▸ Show as Windows puts the host's leftmost monitor on the Mac's leftmost display, and so on. Extra windows go on the last display."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .clipboardSharingConfirmation($askingClipboard) {
            clipboardSharing = $0
        }
        .frame(width: 420)
        .fixedSize()
    }

    private var mode: Binding<CaptureMode> {
        Binding(get: { CaptureMode(stored: inputMode) }, set: { inputMode = $0.stored })
    }

    private var textSize: Binding<TextSize> {
        Binding(
            get: { TextSize(rawValue: virtualTextSize) ?? .mac },
            set: { virtualTextSize = $0.factor })
    }
}
