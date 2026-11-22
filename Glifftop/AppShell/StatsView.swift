import GliffSession
import SwiftUI

/// The live numbers for a streaming session and its stream, for Connection Info.
struct StatsView: View {
    let host: String
    let stream: StreamInfo
    let stats: SessionStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(host)
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("Frame rate", stats.map { "\(Self.number($0.framesPerSecond, digits: 0)) fps" })
                row("Bit rate", stats.map { "\(Self.number($0.megabitsPerSecond, digits: 1)) Mbit/s" })
                row("Round trip", stats?.roundTripMilliseconds.map { "\(Self.number($0, digits: 0)) ms" })
                row("Decode", stats.map { "\(Self.number($0.decodeMilliseconds, digits: 1)) ms" })
                row("Chroma", stream.chroma.displayName)
                row("Encoder", stream.pipeline?.displayName)
                row("Stream", "\(stream.width) × \(stream.height)")
            }
            .font(.callout)
            .monospacedDigit()
            Text("The host draws \(stream.viewWidth) × \(stream.viewHeight)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
        }
    }

    static func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }
}
