import AppKit
import SwiftUI

/// Tells a `CaptureController` its window, and whether the window shows the live picture.
struct CaptureTracker: NSViewRepresentable {
    let controller: CaptureController
    let picture: Bool
    let interrupted: Bool

    func makeNSView(context: Context) -> CaptureTrackerView { CaptureTrackerView() }

    func updateNSView(_ nsView: CaptureTrackerView, context: Context) {
        nsView.report = { [controller, picture, interrupted] window in
            controller.update(window: window, picture: picture, interrupted: interrupted)
        }
        // Not inside SwiftUI's update pass: capture changes observable state and may send.
        Task { nsView.report(nsView.window) }
    }
}

/// `CaptureTracker`'s view: draws nothing, reports its window when it moves to one.
final class CaptureTrackerView: NSView {
    var report: (NSWindow?) -> Void = { _ in }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Not inside SwiftUI's update pass (a window's views come and go during one).
        Task { [window] in report(window) }
    }
}
