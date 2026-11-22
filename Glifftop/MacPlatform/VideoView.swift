import GliffInput
import GliffSession
import GliffVideo
import SwiftUI

/// SwiftUI's handle on `VideoNSView`: the latest picture of `slot` (scaled up to fill with
/// `scaleToFit`), the window fitted by `sizing` (once known) when it changes or `fitRequest` does, the
/// drawable's size and backing scale to `onTarget` from then on, and over the picture the
/// cursor for `cursor`'s shapes, whether input is `captured` and the session headless.
struct VideoView: NSViewRepresentable {
    let slot: PictureSlot
    let renderer: PictureRenderer
    let sizing: WindowSizing?
    /// Points under the picture in the window's content (the status bar): a mirror's window
    /// counts them.
    let extraHeight: CGFloat
    let fitRequest: Int
    let scaleToFit: Bool
    /// The drawable's size in pixels and the backing scale, once fitted and on every change.
    let onTarget: (PixelSize, Double) -> Void
    /// A pointer event over the picture, in remote coordinates: true when it was for the remote.
    let onPointer: (PointerEvent) -> Bool
    let cursor: CursorSlot
    let captured: Bool
    let headless: Bool

    func makeNSView(context: Context) -> VideoNSView {
        VideoNSView(slot: slot, renderer: renderer)
    }

    func updateNSView(_ nsView: VideoNSView, context: Context) {
        // Before `fit`: a first fit counts it.
        nsView.extraHeight = extraHeight
        nsView.fit = sizing.map { VideoNSView.Fit(sizing: $0, request: fitRequest) }
        nsView.scaleToFit = scaleToFit
        nsView.onTarget = onTarget
        nsView.onPointer = onPointer
        nsView.updateCursor(slot: cursor, captured: captured, headless: headless)
    }
}
