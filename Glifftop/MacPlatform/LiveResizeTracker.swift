import AppKit
import SwiftUI
import os

/// The window's live resize (a drag of its edge), for the session: `changed(true)` as one
/// starts, `changed(false)` as it ends, or as the view leaves a window it was in one of. The
/// end is told a turn later, after the views measuring the picture's size have reported the
/// size it ended on in their own `viewDidEndLiveResize`: their ticks could otherwise report it
/// after the end, and the session would send the size before it, then this one.
struct LiveResizeTracker: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> LiveResizeView {
        let view = LiveResizeView()
        view.changed = changed
        return view
    }

    func updateNSView(_ nsView: LiveResizeView, context: Context) { nsView.changed = changed }
}

/// `LiveResizeTracker`'s view: draws nothing; AppKit tells it of its window's live resize.
final class LiveResizeView: NSView {
    private static let logger = Logger(subsystem: "me.cbyrd.Glifftop", category: "window")

    var changed: (Bool) -> Void = { _ in }
    private var inLiveResizeReported = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report(window?.inLiveResize == true)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        report(true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        Task { report(window?.inLiveResize == true) }
    }

    private func report(_ on: Bool) {
        guard on != inLiveResizeReported else { return }
        inLiveResizeReported = on
        Self.logger.debug("live resize \(on ? "started" : "ended", privacy: .public)")
        changed(on)
    }
}
