import GliffSession
import SwiftUI
import UniformTypeIdentifiers

/// The machines (and the connect field), or the session once one has started, titled for it
/// (the machine's name, its screen and state), with the session's controls in the toolbar (shown on hover in full screen).
struct RootView: View {
    @Bindable var model: SessionModel
    @State private var isFullScreen = false
    @AppStorage(AppSettings.shareClipboardKey) private var shareClipboard = false

    var body: some View {
        Group {
            if model.isActive {
                SessionView(model: model)
            } else {
                MachinesView(model: model)
            }
        }
        .frame(minWidth: 360, idealWidth: 420, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        // The window (contentSize resizability) takes its limits from the content. Without the
        // picture, the content is fixed at its ideal size in both directions: the window fits
        // each phase, taller ones aren't clipped, and a window macOS restores at a stream's
        // width comes back to the form's. The picture lets the window resize freely, and so
        // does full screen until the window has left it (`FullScreenTracker`). Free needs the
        // unbounded maximum: the end screen alone is no bigger than its text, and a window
        // whose content can't grow can't use full screen, not even to leave it.
        // One view tree either way: a SessionView swapped for another would disappear, which
        // disconnects.
        .fixedSize(horizontal: isCompact, vertical: isCompact)
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
        .toolbar { SessionToolbar(model: model) }
        .windowToolbarFullScreenVisibility(.onHover)
        .shareClipboardConfirmation(isPresented: $model.confirmingShare) { shareClipboard = true }
        .sheet(item: $model.machineEdit) {
            EditMachineView(model: model, machine: $0.machine, isNew: $0.isNew)
        }
        // Kept while View ▸ Screen reconnects: the new screen opens in full screen too.
        .background {
            FullScreenTracker(isFullScreen: $isFullScreen, wanted: model.picture != nil || model.isSwitching)
        }
        .background {
            CaptureTracker(
                controller: model.capture, picture: model.picture != nil, interrupted: model.isInterrupted)
        }
        .background { ClipboardTracker(controller: model.clipboard) }
        #if DEBUG
            .fileImporter(isPresented: $model.choosingRecordingsDirectory, allowedContentTypes: [.folder]) {
                result in
                guard case .success(let directory) = result else { return }
                model.useRecordingsDirectory(directory)
            }
        #endif
    }

    private var isCompact: Bool { model.picture == nil && !isFullScreen }
}
