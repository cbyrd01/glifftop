import AppKit
import SwiftUI

/// Tells a `ClipboardController` its window, whose key state is "in front". Only a window: a
/// tracker view SwiftUI has replaced reports none, and could do so after its replacement
/// reported the window. The controller holds the window weakly, so a closed one goes anyway.
struct ClipboardTracker: NSViewRepresentable {
    let controller: ClipboardController

    func makeNSView(context: Context) -> CaptureTrackerView { CaptureTrackerView() }

    func updateNSView(_ nsView: CaptureTrackerView, context: Context) {
        nsView.report = { [controller] window in
            if let window { controller.update(window: window) }
        }
        // Not inside SwiftUI's update pass: the controller may send.
        Task { nsView.report(nsView.window) }
    }
}
