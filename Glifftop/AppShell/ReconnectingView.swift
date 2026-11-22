import GliffSession
import SwiftUI

/// Over the last picture, dimmed (a plain scrim, never Liquid Glass on the video), while a lost
/// session is tried again: why it ended, the countdown and the try, Reconnect Now and
/// Disconnect, on a glass panel.
struct ReconnectingView: View {
    let model: SessionModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 12) {
                ProgressView()
                Text("Reconnecting to \(model.title)")
                    .font(.headline)
                if let end = model.reconnectEnd {
                    Text(end.message)
                        .foregroundStyle(.secondary)
                }
                progress
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                HStack {
                    Button("Disconnect", action: model.backToMachines)
                    Button("Reconnect Now", action: model.reconnectNow)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .glassEffect(in: .rect(cornerRadius: 16))
            .padding(24)
        }
    }

    private var tries: Int { ReconnectPolicy.delays.count }

    @ViewBuilder private var progress: some View {
        switch model.reconnectState {
        case .waiting(let attempt, _):
            if let deadline = model.reconnectDeadline {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                    Text("Trying again in \(seconds) s (attempt \(attempt) of \(tries))")
                }
            }
        case .waitingForNetwork(let attempt):
            Text("Waiting for the network (attempt \(attempt) of \(tries))")
        case .trying(let attempt):
            Text("Trying now (attempt \(attempt) of \(tries))")
        case nil:
            EmptyView()
        }
    }
}
