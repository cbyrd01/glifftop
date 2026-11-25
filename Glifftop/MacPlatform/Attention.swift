import AppKit
import SwiftUI

/// Draws the person to the window's sign-in question: each new `question` selects the window's
/// tab and brings it forward while Glifftop is the active app; otherwise the Dock icon bounces
/// once, the focus stays where the person has it, and the window whose question bounced last
/// comes forward, once, when Glifftop is next made active (its sheet waits for that:
/// `signInSheet`).
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

    /// The view whose question last bounced the Dock icon, to come forward on activation.
    private static weak var bounced: AttentionView?
    private var activation: (any NSObjectProtocol)?

    init() {
        super.init(frame: .zero)
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Self.bounced === self else { return }
                Self.bounced = nil
                if self.question != nil { self.request() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if question != nil { request() }
    }

    isolated deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    private func request() {
        guard let window else { return }
        guard NSApp.isActive else {
            NSApp.requestUserAttention(.informationalRequest)
            Self.bounced = self
            return
        }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}
