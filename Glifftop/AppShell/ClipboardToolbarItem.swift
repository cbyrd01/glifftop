import SwiftUI

/// The toolbar's Share the clipboard: the app's setting, asking first when turned on (as
/// Settings does; the window shows the question, as the toolbar may be hidden), and beside it the host's read of the Mac clipboard with Cancel while it runs.
struct ClipboardToolbarItem: View {
    @Bindable var model: SessionModel
    @AppStorage(AppSettings.shareClipboardKey) private var shareClipboard = false

    var body: some View {
        // No spacing of its own: with no read shown, the item's glass is the button's alone.
        HStack(spacing: 0) {
            Toggle(
                "Share the clipboard", systemImage: "clipboard",
                isOn: .askingFirst($shareClipboard, confirming: $model.confirmingShare)
            )
            .toggleStyle(.button)
            // One clipboard, filled while shared.
            .symbolVariant(shareClipboard ? .fill : .none)
            .help(shareClipboard ? "Stop sharing the clipboard" : "Share the clipboard")
            ClipboardReadView(
                activity: model.clipboardActivity, host: model.host, cancel: model.cancelClipboardServing,
                dismissed: $model.dismissedClipboardRun, leading: 8)
        }
    }
}
