import SwiftUI

/// Over a picture that may be stale: the server has gone quiet. The picture dims (a plain
/// scrim, never Liquid Glass on the video) under a glass panel that says so, until traffic
/// resumes or the link is given up for lost; Reconnect Now gives it up at once.
struct InterruptionView: View {
    let host: String
    let backToMachines: () -> Void
    let reconnectNow: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 12) {
                ProgressView()
                Text("Connection interrupted")
                    .font(.headline)
                Text("Waiting for \(host) to respond…")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Disconnect", action: backToMachines)
                    Button("Reconnect Now", action: reconnectNow)
                }
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .glassEffect(in: .rect(cornerRadius: 16))
            .padding(24)
        }
    }
}
