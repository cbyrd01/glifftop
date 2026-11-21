import AppKit
import SwiftUI

/// Tells a `ClipboardController` its window, whose key state is "in front".
struct ClipboardTracker: NSViewRepresentable {
    let controller: ClipboardController

    func makeNSView(context: Context) -> CaptureTrackerView { CaptureTrackerView() }

    func updateNSView(_ nsView: CaptureTrackerView, context: Context) {
        nsView.report = { [controller] window in controller.update(window: window) }
        // Not inside SwiftUI's update pass: the controller may send.
        Task { nsView.report(nsView.window) }
    }
}
