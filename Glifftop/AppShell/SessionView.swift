import GliffSession
import SwiftUI

/// A running session: progress while connecting, the picture while streaming, and why it ended.
struct SessionView: View {
    let model: SessionModel

    var body: some View {
        // A container, not a Group: a Group would hand onDisappear to each branch, and the
        // status view disappearing when the first picture arrives would disconnect.
        ZStack {
            if let picture = model.picture {
                StreamingView(model: model, stream: picture.stream, renderer: picture.renderer)
            } else {
                status
                    .padding(24)
            }
        }
        .onDisappear(perform: model.disconnect)
    }

    private var status: some View {
        VStack(spacing: 16) {
            switch model.snapshot.phase {
            case .idle, .connecting, .handshaking:
                ProgressView()
                Text("Connecting to \(model.host)…")
                Button("Cancel", action: model.disconnect)
                    .keyboardShortcut(.cancelAction)
            case .waitingForVideo, .streaming:
                ProgressView()
                Text("Waiting for video from \(model.host)…")
                Button("Disconnect", action: model.disconnect)
            case .ended:
                Text(model.snapshot.end?.message ?? "Disconnected.")
                    .multilineTextAlignment(.center)
                Button("Back", action: model.reset)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
