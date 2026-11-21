import GliffTransport
import SwiftUI

/// The app's defaults (Settings), stored in `UserDefaults`: the screen a connection
/// from the form starts on, the window's text size and Scale to Fit at each connection, and
/// whether the clipboard is shared.
enum AppSettings {
    /// "focused" or "virtual".
    static let connectScreenKey = "connectScreen"
    /// A `TextSize` factor.
    static let virtualTextSizeKey = "virtualTextSize"
    static let scaleToFitKey = "scaleToFit"
    /// "Share the clipboard": off until turned on, which asks first.
    static let shareClipboardKey = "shareClipboard"

    static var connectScreen: ScreenChoice {
        UserDefaults.standard.string(forKey: connectScreenKey) == "virtual" ? .virtual : .focused
    }
    static var virtualTextSize: TextSize {
        TextSize(rawValue: UserDefaults.standard.double(forKey: virtualTextSizeKey)) ?? .mac
    }
    static var scaleToFit: Bool { UserDefaults.standard.bool(forKey: scaleToFitKey) }
    static var shareClipboard: Bool { UserDefaults.standard.bool(forKey: shareClipboardKey) }
}

/// Settings ▸ General: the defaults each new connection starts from.
struct SettingsView: View {
    @AppStorage(AppSettings.connectScreenKey) private var connectScreen = "focused"
    @AppStorage(AppSettings.virtualTextSizeKey) private var virtualTextSize = TextSize.mac.factor
    @AppStorage(AppSettings.scaleToFitKey) private var scaleToFit = false
    @AppStorage(AppSettings.shareClipboardKey) private var shareClipboard = false
    @State private var confirmingShare = false

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
            Toggle("Share the clipboard", isOn: sharing)
        }
        .formStyle(.grouped)
        .alert("Share the clipboard with the remote computer?", isPresented: $confirmingShare) {
            Button("Cancel", role: .cancel) {}
            Button("Share") { shareClipboard = true }
        } message: {
            Text(
                "While Glifftop is in front, anything you copy on this Mac, passwords included, is sent to the remote computer, where its apps can read it and its clipboard tools may keep it. Copies made on the remote computer come to this Mac."
            )
        }
        .frame(width: 420)
        .fixedSize()
    }

    /// Turning sharing on asks first; turning it off doesn't.
    private var sharing: Binding<Bool> {
        Binding(
            get: { shareClipboard },
            set: { on in
                if on { confirmingShare = true } else { shareClipboard = false }
            })
    }

    private var textSize: Binding<TextSize> {
        Binding(
            get: { TextSize(rawValue: virtualTextSize) ?? .mac },
            set: { virtualTextSize = $0.factor })
    }
}
