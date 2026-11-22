import GliffClipboard
import SwiftUI

/// The host reading this Mac's clipboard, compact for the toolbar and the status bar: what and
/// the bytes so far, with Cancel, while it runs (reported only after a second); why for 3 s if it
/// failed; nothing once it finished or was cancelled. No glass of its own.
struct ClipboardReadView: View {
    let activity: ClipboardActivity?
    let host: String
    let cancel: () -> Void
    /// The read whose failure was already shown for its 3 s, shared by every view of the
    /// session's reads.
    @Binding var dismissed: Int?
    /// Space before it while shown (none while hidden).
    var leading: CGFloat = 0

    var body: some View {
        ZStack {
            if let activity, isShown(activity) {
                HStack(spacing: 8) {
                    if activity.state == .running {
                        ProgressView().controlSize(.small)
                    }
                    Text(summary(activity))
                        .lineLimit(1)
                    if activity.state == .running {
                        Button("Cancel", action: cancel)
                            .controlSize(.small)
                    }
                }
                .padding(.leading, leading)
                .help("\(host) is pasting \(activity.label) from this Mac")
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

    /// "Pasting text · 1.2 MB", or why it failed.
    private func summary(_ activity: ClipboardActivity) -> String {
        if case .failed(let message) = activity.state { return message }
        return
            "Pasting \(activity.label) · \(Int64(clamping: activity.done).formatted(.byteCount(style: .file)))"
    }
}
