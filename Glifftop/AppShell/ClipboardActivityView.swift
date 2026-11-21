import GliffClipboard
import SwiftUI

/// The host reading this Mac's clipboard, over the picture: what, the bytes so far
/// and Cancel while it runs (reported only after a second), why for 3 s if it failed, nothing
/// once it finished or was cancelled. Temporary chrome, as the stats are.
/// Glass on this panel only, never on the video.
struct ClipboardActivityView: View {
    let activity: ClipboardActivity?
    let host: String
    let cancel: () -> Void
    /// The read whose failure was already shown for its 3 s.
    @State private var dismissed: Int?

    var body: some View {
        ZStack {
            if let activity, isShown(activity) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(host) is pasting \(activity.label) from this Mac")
                            .font(.callout.weight(.semibold))
                        Text(detail(activity))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if activity.state == .running {
                        ProgressView().controlSize(.small)
                        Button("Cancel", action: cancel)
                    }
                }
                .padding(12)
                .glassEffect(in: .rect(cornerRadius: 12))
                .padding(12)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activity.map(isShown))
        .task(id: activity) {
            guard let activity, case .failed = activity.state else { return }
            // Cut short (the view went, or the activity changed): not shown its 3 s yet.
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            dismissed = activity.run
        }
    }

    private func isShown(_ activity: ClipboardActivity) -> Bool {
        switch activity.state {
        case .running: true
        case .failed: activity.run != dismissed
        case .done, .cancelled: false
        }
    }

    private func detail(_ activity: ClipboardActivity) -> String {
        if case .failed(let message) = activity.state { return message }
        return "\(Int64(clamping: activity.done).formatted(.byteCount(style: .file))) sent"
    }
}
