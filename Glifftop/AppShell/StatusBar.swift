import GliffSession
import SwiftUI

/// Under the picture with View ▸ Show Status Bar: the state, the live numbers, the encoding,
/// and the host's read of the Mac clipboard with Cancel. The bar material, never glass, and
/// never over the picture: the window's fit counts its height.
struct StatusBar: View {
    static let height: CGFloat = 28

    @Bindable var model: SessionModel
    let stream: StreamInfo

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isInterrupted || model.isReconnecting ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(model.stateWord)
            }
            if let stats = model.snapshot.stats {
                Text("\(StatsView.number(stats.framesPerSecond, digits: 0)) fps")
                Text("\(StatsView.number(stats.megabitsPerSecond, digits: 1)) Mbit/s")
                if let roundTrip = stats.roundTripMilliseconds {
                    Text("\(StatsView.number(roundTrip, digits: 0)) ms")
                }
            }
            Text(
                [stream.chroma.displayName, stream.pipeline?.displayName].compactMap(\.self).joined(
                    separator: " · "))
            Spacer(minLength: 0)
            ClipboardReadView(
                activity: model.clipboardActivity, host: model.host, cancel: model.cancelClipboardServing,
                dismissed: $model.dismissedClipboardRun)
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .background(.bar)
    }
}
