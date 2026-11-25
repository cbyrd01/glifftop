import AppKit
import SwiftUI

/// Draws the person to the window's sign-in question: each new `question` selects the window's
/// tab and brings it forward while Glifftop is the active app and the window isn't minimized;
/// otherwise the Dock icon bounces once, the icon's badge counts the questions open in minimized
/// windows, and the focus stays where the person has it. The window whose question
/// bounced last comes forward, its tab selected, once Glifftop is active and it isn't minimized. `readyChanged` says whether the
/// window may take a new sheet: Glifftop is active and the window isn't minimized
/// (`signInSheet` waits for that).
struct AttentionTracker: NSViewRepresentable {
    /// The question shown (`SignInQueue.Pending.id`), nil while none is.
    let question: Int?
    let readyChanged: (Bool) -> Void

    func makeNSView(context: Context) -> AttentionView { AttentionView(readyChanged: readyChanged) }

    func updateNSView(_ nsView: AttentionView, context: Context) {
        nsView.readyChanged = readyChanged
        nsView.question = question
    }
}

/// `AttentionTracker`'s view: draws nothing, asks for attention for its window.
final class AttentionView: NSView {
    var question: Int? {
        didSet {
            if question != nil, question != oldValue { request() }
            updateBadge()
        }
    }
    var readyChanged: (Bool) -> Void

    /// The view whose question last bounced the Dock icon, to come forward on activation.
    private static weak var bounced: AttentionView?
    private var observers: [any NSObjectProtocol] = []
    private var reportedReady: Bool?
    /// The views whose question is open in a minimized window, counted on Glifftop's icon.
    private static var badging: Set<ObjectIdentifier> = []

    /// The window as the Dock holds it: its tab group's selected window, which a minimized
    /// group's tabs share.
    private var shownWindow: NSWindow? { window.map { $0.tabGroup?.selectedWindow ?? $0 } }

    private var isMinimized: Bool {
        window?.isMiniaturized == true || shownWindow?.isMiniaturized == true
    }

    /// Glifftop is active and the window isn't minimized.
    private var isReady: Bool { NSApp.isActive && !isMinimized }

    /// `readyChanged` is set before the view joins a window, so its first report is heard.
    init(readyChanged: @escaping (Bool) -> Void) {
        self.readyChanged = readyChanged
        super.init(frame: .zero)
        let center = NotificationCenter.default
        let changes: [(Notification.Name, @MainActor (AttentionView) -> Void)] = [
            (NSApplication.didBecomeActiveNotification, { $0.windowChanged() }),
            (NSApplication.didResignActiveNotification, { $0.windowChanged() }),
            // Any window's: a minimized tab group is its selected window.
            (NSWindow.didMiniaturizeNotification, { $0.windowChanged() }),
            (NSWindow.didDeminiaturizeNotification, { $0.windowChanged() }),
        ]
        observers = changes.map { name, action in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged()
        if question != nil { request() }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        Self.badge(ObjectIdentifier(self), false)
    }

    private func windowChanged() {
        let ready = isReady
        // The window that bounced last comes forward, its tab selected, once it can: Glifftop
        // made active, or the window out of the Dock.
        if ready, Self.bounced === self, window != nil {
            Self.bounced = nil
            if question != nil { request() }
        }
        updateBadge()
        // A view out of its window has no say: SwiftUI may add the window's next tracker before
        // removing this one, and the window's state is the new one's to report.
        guard window != nil else {
            reportedReady = nil
            return
        }
        guard ready != reportedReady else { return }
        reportedReady = ready
        readyChanged(ready)
    }

    /// Glifftop's Dock icon counts the questions open in minimized windows: the Dock icon's
    /// bounce goes unseen while Glifftop is active.
    private func updateBadge() {
        Self.badge(ObjectIdentifier(self), question != nil && isMinimized)
    }

    private static func badge(_ view: ObjectIdentifier, _ on: Bool) {
        guard on != badging.contains(view) else { return }
        if on { badging.insert(view) } else { badging.remove(view) }
        NSApp.dockTile.badgeLabel = badging.isEmpty ? nil : String(badging.count)
    }

    private func request() {
        guard let window else { return }
        guard isReady else {
            NSApp.requestUserAttention(.informationalRequest)
            Self.bounced = self
            return
        }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}
