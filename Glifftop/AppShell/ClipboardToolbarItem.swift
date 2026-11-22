import SwiftUI

/// The toolbar's clipboard sharing: one button that steps through the app's setting (Not
/// shared, Shared, Shared including passwords, and back), asking first before each step that
/// sends more (the window shows the question, as the toolbar may be hidden); beside it, the
/// host's read of the Mac clipboard with Cancel while it runs.
struct ClipboardToolbarItem: View {
    @Bindable var model: SessionModel
    @StoredClipboardSharing private var sharing

    var body: some View {
        // No spacing of its own: with no read shown, the item's glass is the button's alone.
        HStack(spacing: 0) {
            Button {
                Binding.askingFirst($sharing, asking: $model.askingClipboard).wrappedValue = sharing.next
            } label: {
                ClipboardSharingIcon(sharing: sharing)
            }
            .help(sharing.help)
            .accessibilityLabel("Share the clipboard")
            .accessibilityValue(sharing.label)
            ClipboardReadView(
                activity: model.clipboardActivity, host: model.host, cancel: model.cancelClipboardServing,
                dismissed: $model.dismissedClipboardRun, leading: 8)
        }
    }
}

/// A clipboard with lines on its page: an outline while not shared, filled blue while shared,
/// orange with a key while passwords go too.
private struct ClipboardSharingIcon: View {
    let sharing: ClipboardSharing

    var body: some View {
        switch sharing {
        case .off:
            Image(systemName: "list.clipboard")
        case .shared:
            Image(systemName: "list.clipboard.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .blue)
        case .withPasswords:
            Image(systemName: "list.clipboard.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .orange)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(.orange, in: .circle)
                        .offset(x: 4, y: 3)
                }
        }
    }
}
