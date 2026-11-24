import AppKit
import SwiftUI

/// Draws the person to the window's sign-in question: each new `question` selects the window's
/// tab and brings it forward while Glifftop is the active app; otherwise the Dock icon bounces
/// once, and the focus stays where the person has it.
struct AttentionTracker: NSViewRepresentable {
    /// The question shown (`SignInQueue.Pending.id`), nil while none is.
    let question: Int?

    func makeNSView(context: Context) -> AttentionView { AttentionView() }

    func updateNSView(_ nsView: AttentionView, context: Context) { nsView.question = question }
}

/// `AttentionTracker`'s view: draws nothing, asks for attention for its window.
final class AttentionView: NSView {
    var question: Int? {
        didSet { if question != nil, question != oldValue { request() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if question != nil { request() }
    }

    private func request() {
        guard let window else { return }
        guard NSApp.isActive else {
            NSApp.requestUserAttention(.informationalRequest)
            return
        }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}
