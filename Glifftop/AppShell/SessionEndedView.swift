import GliffSession
import SwiftUI

/// Why the session ended: "Couldn't reconnect to …" once the tries ran out, else "Disconnected
/// from …", the reason, and Try Again (when there's a host to try), Edit Machine… (once the
/// host is a machine) and Close (back to the machines).
struct SessionEndedView: View {
    let model: SessionModel

    var body: some View {
        VStack(spacing: 12) {
            Text(headline)
                .font(.headline)
            Text(model.snapshot.end?.message ?? "Disconnected.")
                .foregroundStyle(.secondary)
            HStack {
                if model.machine != nil {
                    Button("Edit Machine…", action: model.editMachine)
                }
                Button("Close", action: model.reset)
                    .keyboardShortcut(.cancelAction)
                if model.canTryAgain {
                    Button("Try Again", action: model.tryAgain)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .multilineTextAlignment(.center)
    }

    /// The host is gone when the session never started (no GPU video): just "Disconnected".
    private var headline: String {
        guard !model.host.isEmpty else { return "Disconnected" }
        return model.gaveUp ? "Couldn't reconnect to \(model.title)" : "Disconnected from \(model.title)"
    }
}
