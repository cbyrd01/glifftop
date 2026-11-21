import GliffProtocol
import GliffSession
import GliffVideo
import SwiftUI

/// The remote picture filling the window, with the stats and Disconnect overlaid at the top
/// trailing corner, the input hint at the bottom for a few seconds after capture, the host's
/// read of the Mac clipboard at the bottom leading corner, and the interruption panel over all
/// of it while the server is quiet.
/// Liquid Glass on the overlays only, never the video.
struct StreamingView: View {
    let model: SessionModel
    let stream: StreamInfo
    let renderer: PictureRenderer

    var body: some View {
        VideoView(
            slot: model.slot, renderer: renderer,
            sizing: model.windowSizing,
            fitRequest: model.actualSizeRequests, scaleToFit: model.scaleToFit,
            onTarget: model.viewTargetChanged, onPointer: model.capture.pointer, cursor: model.viewCursor,
            captured: model.capture.isCaptured, headless: model.snapshot.session?.headless ?? false
        )
        // A new session's slot gets a new video view: the old one would keep drawing the old slot.
        .id(ObjectIdentifier(model.slot))
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                if model.showsStatistics {
                    StatsView(host: model.host, stream: stream, stats: model.snapshot.stats)
                }
                Button("Disconnect", action: model.disconnect)
            }
            .padding(12)
            .glassEffect(in: .rect(cornerRadius: 12))
            .padding(12)
        }
        .overlay(alignment: .bottom) {
            // Its own container, so the fade animates only the hint; clicks go through to
            // the picture under it.
            ZStack {
                if model.capture.showsHint {
                    InputHintView()
                        .padding(24)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.capture.showsHint)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            ClipboardActivityView(
                activity: model.snapshot.clipboard, host: model.host, cancel: model.cancelClipboardServing)
        }
        // Over everything, stats included: while the server is quiet nothing below is live.
        .overlay {
            if model.snapshot.isInterrupted {
                InterruptionView(host: model.host, disconnect: model.disconnect)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.snapshot.isInterrupted)
    }
}
