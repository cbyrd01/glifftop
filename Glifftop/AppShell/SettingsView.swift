import GliffSession
import GliffTransport
import SwiftUI

/// The app's defaults (Settings), stored in `UserDefaults`: the screen a connection
/// from the form starts on, the window's text size and Scale to Fit at each connection, and
/// whether the clipboard is shared, passwords included or not.
enum AppSettings {
    /// "focused" or "virtual".
    static let connectScreenKey = "connectScreen"
    /// A `TextSize` factor.
    static let virtualTextSizeKey = "virtualTextSize"
    static let scaleToFitKey = "scaleToFit"
    /// "Share the clipboard": off until turned on, which asks first.
    static let shareClipboardKey = "shareClipboard"
    /// "Include passwords": a password manager's copies are offered too. Off until turned on,
    /// which asks first.
    static let includePasswordsKey = "includePasswords"
    /// View ▸ Show Status Bar, app-wide; off by default.
    static let showsStatusBarKey = "showsStatusBar"

    static var connectScreen: ScreenChoice {
        UserDefaults.standard.string(forKey: connectScreenKey) == "virtual" ? .virtual : .focused
    }
    static var virtualTextSize: TextSize {
        TextSize(rawValue: UserDefaults.standard.double(forKey: virtualTextSizeKey)) ?? .mac
    }
    static var scaleToFit: Bool { UserDefaults.standard.bool(forKey: scaleToFitKey) }
    static var shareClipboard: Bool { UserDefaults.standard.bool(forKey: shareClipboardKey) }
    static var includePasswords: Bool { UserDefaults.standard.bool(forKey: includePasswordsKey) }
}

/// Settings ▸ General: the defaults each new connection starts from.
struct SettingsView: View {
    @AppStorage(AppSettings.connectScreenKey) private var connectScreen = "focused"
    @AppStorage(AppSettings.virtualTextSizeKey) private var virtualTextSize = TextSize.mac.factor
    @AppStorage(AppSettings.scaleToFitKey) private var scaleToFit = false
    @AppStorage(AppSettings.shareClipboardKey) private var shareClipboard = false
    @AppStorage(AppSettings.includePasswordsKey) private var includePasswords = false
    @State private var confirmingShare = false
    @State private var confirmingPasswords = false

    var body: some View {
        Form {
            Picker("Connect to", selection: $connectScreen) {
                Text(ScreenChoice.focused.label).tag("focused")
                Text(ScreenChoice.virtual.label).tag("virtual")
            }
            // Through TextSize: a stored factor that's no step shows as the one connections use.
            Picker("Virtual screen text size", selection: textSize) {
                ForEach(TextSize.allCases) { Text($0.label()).tag($0) }
            }
            Toggle("Scale smaller screens to fit", isOn: $scaleToFit)
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
