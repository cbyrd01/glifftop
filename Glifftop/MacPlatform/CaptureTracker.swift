import AppKit
import SwiftUI

/// Tells a `CaptureController` its window, whether the window shows the live picture, and
/// whether a popover is over it.
struct CaptureTracker: NSViewRepresentable {
    let controller: CaptureController
    let picture: Bool
    let interrupted: Bool
    let popover: Bool

    func makeNSView(context: Context) -> CaptureTrackerView { CaptureTrackerView() }

    func updateNSView(_ nsView: CaptureTrackerView, context: Context) {
        nsView.report = { [controller, picture, interrupted, popover] window in
            controller.update(window: window, picture: picture, interrupted: interrupted, popover: popover)
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
