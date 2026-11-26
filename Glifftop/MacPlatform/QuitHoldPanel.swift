import AppKit
import GliffInput
import SwiftUI

/// "Hold ⌘Q to Quit": a borderless, non-activating, click-through panel centred on the key
/// window's screen (the main screen without one), floating and joining full-screen Spaces.
/// Liquid Glass on the panel's own content only. Showing it asks VoiceOver to say it.
@MainActor final class QuitHoldPanel {
    private static let size = NSSize(width: 300, height: 72)
    /// The fade once `QuitHold` says to hide, in seconds.
    private static let fade = 0.2

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: QuitHoldMessage(size: Self.size))
        return panel
    }()
    /// Whether it should be showing: a fade's end orders it out only if it is still hidden.
    private var showing = false

    func show() {
        showing = true
        // An animation, so it replaces a fade still running.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        if let frame = (NSApp.keyWindow?.screen ?? NSScreen.main)?.frame {
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - Self.size.width / 2, y: frame.midY - Self.size.height / 2))
        }
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: String(localized: "Hold Command Q to quit"),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    /// Fades out, then leaves the screen unless shown again meanwhile.
    func hide() {
        guard showing else { return }
        showing = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.showing else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}

/// The panel's message, in the title style on glass.
private struct QuitHoldMessage: View {
    let size: NSSize

    var body: some View {
        Text("Hold ⌘Q to Quit")
            .font(.title)
            .frame(width: size.width, height: size.height)
            .glassEffect(in: .rect(cornerRadius: 18))
    }
}
