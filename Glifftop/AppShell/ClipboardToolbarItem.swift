import GliffClipboard
import GliffMachines
import SwiftUI

/// The toolbar's clipboard sharing: one button that steps the machine's own setting from the
/// one in force (Not shared, Shared, Shared including passwords, and back), asking first before
/// each step that sends more (the window shows the question, as the toolbar may be hidden);
/// beside it, the host's read of the Mac clipboard with Cancel while it runs.
struct ClipboardToolbarItem: View {
    @Bindable var model: SessionModel
    /// Settings', read here so the button follows a change there.
    @StoredClipboardSharing private var settings

    /// As `SessionModel.clipboardInForce`, with Settings' read through the view.
    private var sharing: ClipboardSharing {
        MachineOptions.clipboard(saved: model.machine, window: model.clipboardSharing, settings: settings)
    }

    var body: some View {
        // No spacing of its own: with no read shown, the item's glass is the button's alone.
        HStack(spacing: 0) {
            Button {
                let machine = Binding(get: { sharing }, set: { model.clipboardSharing = $0 })
                Binding.askingFirst(machine, asking: $model.askingClipboard).wrappedValue = sharing.next
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
