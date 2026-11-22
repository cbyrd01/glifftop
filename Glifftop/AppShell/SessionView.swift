import GliffSession
import SwiftUI

/// A running session: progress while connecting, the picture while streaming (the last one,
/// dimmed, while reconnecting), and why it ended.
struct SessionView: View {
    let model: SessionModel

    var body: some View {
        // A container, not a Group: a Group would hand onDisappear to each branch, and the
        // status view disappearing when the first picture arrives would disconnect.
        ZStack {
            if let picture = model.picture {
                StreamingView(model: model, stream: picture.stream, renderer: picture.renderer)
            } else if model.isReconnecting {
                ReconnectingView(model: model)
            } else {
                status
                    .padding(24)
            }
        }
        .onDisappear(perform: model.stopSession)
    }

    private var status: some View {
        VStack(spacing: 16) {
            switch model.snapshot.phase {
            case .idle, .connecting, .handshaking:
                ProgressView()
                Text("Connecting to \(model.host)…")
                Button("Cancel", action: model.backToMachines)
                    .keyboardShortcut(.cancelAction)
            case .waitingForVideo, .streaming:
                ProgressView()
                Text("Waiting for video from \(model.host)…")
                Button("Disconnect", action: model.backToMachines)
            case .ended:
                SessionEndedView(model: model)
            }
        }
    }
}
