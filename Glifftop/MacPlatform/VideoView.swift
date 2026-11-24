import GliffInput
import GliffSession
import GliffVideo
import SwiftUI

/// SwiftUI's handle on `VideoNSView`: the latest picture of `slot` (scaled up to fill with
/// `scaleToFit`), the window fitted by `sizing` (once known) when it changes or `fitRequest` does
/// (never while it `sharesWindow` with other tabs), the
/// drawable's size and backing scale to `onTarget` from then on, and over the picture the
/// cursor for `cursor`'s shapes, whether input is `captured` and the session headless.
struct VideoView: NSViewRepresentable {
    let slot: PictureSlot
    let renderer: PictureRenderer
    let sizing: WindowSizing?
    /// False for a reconnect's session: the window keeps the size it has.
    let fitsWindow: Bool
    /// Points under the picture in the window's content (the status bar): a mirror's window
    /// counts them.
    let extraHeight: CGFloat
    let fitRequest: Int
    /// The window has other tabs: never sized for the session.
    let sharesWindow: Bool
    let scaleToFit: Bool
    /// The drawable's size in pixels and the backing scale, once fitted and on every change.
    let onTarget: (PixelSize, Double) -> Void
    /// Takes the pointer events over the picture, in remote coordinates, and asks the view
    /// where the Mac pointer is over it, for an activation.
    let capture: CaptureController
    let cursor: CursorSlot
    let captured: Bool
    let headless: Bool

    func makeNSView(context: Context) -> VideoNSView {
        VideoNSView(slot: slot, renderer: renderer)
    }

    func updateNSView(_ nsView: VideoNSView, context: Context) {
        // Before `fit`: a first fit counts it.
        // Before `extraHeight`: a shared window never grows for the status bar.
        nsView.sharesWindow = sharesWindow
        nsView.extraHeight = extraHeight
        nsView.fitsWindow = fitsWindow
        nsView.fit = sizing.map { VideoNSView.Fit(sizing: $0, request: fitRequest) }
        nsView.scaleToFit = scaleToFit
        nsView.onTarget = onTarget
        nsView.onPointer = capture.pointer
        capture.macPointer = { [weak nsView] in nsView?.macPointerOverPicture() }
        nsView.updateCursor(slot: cursor, captured: captured, headless: headless)
    }
}
