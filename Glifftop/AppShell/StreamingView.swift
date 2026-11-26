import GliffInput
import GliffProtocol
import GliffSession
import GliffVideo
import SwiftUI

/// The remote picture filling the window (below the toolbar, never under it), the input hint
/// at the bottom for a few seconds after capture and a new port notice above it, the
/// interruption panel over it while the server is quiet, and under it the status bar when
/// View ▸ Show Status Bar is on. Liquid Glass on the overlays only, never the video.
struct StreamingView: View {
    @Bindable var model: SessionModel
    let stream: StreamInfo
    let renderer: PictureRenderer
    @AppStorage(AppSettings.showsStatusBarKey) private var showsStatusBar = false

    var body: some View {
        VStack(spacing: 0) {
            picture
            if showsStatusBar {
                StatusBar(model: model, stream: stream)
            }
        }
    }

    private var picture: some View {
        VideoView(
            slot: model.shownSlot, renderer: renderer,
            sizing: model.windowSizing, fitsWindow: !model.keepsWindow,
            extraHeight: showsStatusBar ? StatusBar.height : 0,
            fitRequest: model.actualSizeRequests, sharesWindow: model.sharesWindow,
            scaleToFit: model.drawsScaled,
            onTarget: model.viewTargetChanged, capture: model.capture,
            cursor: model.viewCursor,
            captured: model.capture.isCaptured,
            videoHasPointer: CursorLook.videoHasPointer(model.snapshot.session)
        )
        // A new session's slot gets a new video view: the old one would keep drawing the old slot.
        .id(ObjectIdentifier(model.shownSlot))
        .overlay(alignment: .bottom) {
            // Its own container, so the fade animates only these; clicks on the hint go through
            // to the picture under it. A new port notice stands above the hint.
            VStack(spacing: 12) {
                PortsNoticeCapsule(session: model, statusBarShown: showsStatusBar)
                if model.capture.showsHint {
                    InputHintView()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .padding(24)
            .animation(.easeInOut(duration: 0.2), value: model.capture.showsHint)
        }
        // Connection Info (⌘I, the toolbar's ⓘ) from the picture's top trailing corner, under
        // the ⓘ: the toolbar may be hidden (full screen) or the item in its overflow.
        .overlay(alignment: .topTrailing) {
            Color.clear
                .frame(width: 1, height: 1)
                .popover(isPresented: $model.showsConnectionInfo, arrowEdge: .top) {
                    ConnectionInfoView(model: model)
                }
        }
        // While the server is quiet, or the session is being tried again, nothing below is live.
        .overlay {
            if model.isReconnecting {
                ReconnectingView(model: model)
                    .transition(.opacity)
            } else if model.snapshot.isInterrupted {
                InterruptionView(
                    host: model.host, backToMachines: model.backToMachines, reconnectNow: model.reconnectNow
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if model.showsVirtualNotice {
                Text("Windows from the old virtual screen are on the host's other monitor")
                    .padding(12)
                    .glassEffect(in: .capsule)
                    .padding(16)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.snapshot.isInterrupted)
        .animation(.easeInOut(duration: 0.2), value: model.isReconnecting)
        .animation(.easeInOut(duration: 0.2), value: model.showsVirtualNotice)
    }
}
