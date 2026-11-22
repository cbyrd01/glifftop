import GliffSession
import GliffTransport
import SwiftUI

/// Why the session ended: "Couldn't reconnect to …" once the tries ran out, "Couldn't connect
/// to …" when it never got through, else "Disconnected from …"; the reason; and Try Again
/// (when there's a host to try), Edit Machine… (once the host is a machine) and Close (back to
/// the machines). A monitor the host doesn't have is said plainly, with the screens that are
/// always there to use instead.
struct SessionEndedView: View {
    let model: SessionModel

    var body: some View {
        VStack(spacing: 12) {
            Text(headline)
                .font(.headline)
            Text(reason)
                .foregroundStyle(.secondary)
            if model.missingMonitor != nil {
                // Either starts a session now, and its machine keeps the screen it shows.
                HStack {
                    Button("Use Virtual Screen") { model.switchScreen(.virtual) }
                    Button("Use Focused Monitor") { model.switchScreen(.focused) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            HStack {
                if model.machine != nil {
                    Button("Edit Machine…", action: model.editMachine)
                }
                Button("Close", action: model.backToMachines)
                    .keyboardShortcut(.cancelAction)
                if model.canTryAgain {
                    Button("Try Again", action: model.tryAgain)
                        .keyboardShortcut(model.missingMonitor == nil ? .defaultAction : nil)
                }
            }
        }
        .multilineTextAlignment(.center)
    }

    private var reason: String {
        if let monitor = model.missingMonitor {
            return "\(monitor) isn't connected on \(model.host). Use another screen, or try again once it is."
        }
        return model.snapshot.end?.message ?? "Disconnected."
    }

    /// The host is gone when the session never started (no GPU video): just "Disconnected".
    private var headline: String {
        guard !model.host.isEmpty else { return "Disconnected" }
        if model.gaveUp { return "Couldn't reconnect to \(model.title)" }
        return model.neverConnected
            ? "Couldn't connect to \(model.title)" : "Disconnected from \(model.title)"
    }
}
