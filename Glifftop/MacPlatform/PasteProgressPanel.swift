import AppKit

/// The floating panel for a paste on the Mac that takes a while: what is coming, the
/// bytes so far, an indeterminate bar and Cancel; on failure, why, for 3 s. Non-activating, so
/// it shows over the app being pasted into without taking its focus.
final class PasteProgressPanel: NSObject {
    private let panel: NSPanel
    private let status = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let button = NSButton(title: "Cancel", target: nil, action: nil)
    private let onCancel: () -> Void

    /// Shows the panel for a paste of `label` ("text", "HTML", "image") from `host` (as typed).
    init(label: String, host: String, onCancel: @escaping () -> Void = {}) {
        self.onCancel = onCancel
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 96),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = "Glifftop"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Pasting \(label) from \(host)")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        bar.isIndeterminate = true
        bar.style = .bar
        bar.startAnimation(nil)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.preferredMaxLayoutWidth = 220
        button.target = self
        button.action = #selector(cancelPressed)
        let row = NSStackView(views: [status, button])
        row.distribution = .fill
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [title, bar, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in [bar, row] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        panel.contentView = stack
        update(done: 0)
        panel.center()
        panel.orderFrontRegardless()
    }

    /// Bytes received so far (no total is known ahead).
    func update(done: UInt64) {
        let text = "\(Int64(clamping: done).formatted(.byteCount(style: .file))) received"
        if status.stringValue != text { status.stringValue = text }
    }

    /// Why the paste failed, shown for 3 s; then the panel closes. The close task keeps the panel
    /// alive until then: its creator lets go at once.
    func fail(_ message: String) {
        bar.stopAnimation(nil)
        bar.isHidden = true
        status.stringValue = message
        button.title = "OK"
        button.action = #selector(close)
        if !panel.isVisible { panel.orderFrontRegardless() }
        Task {
            try? await Task.sleep(for: .seconds(3))
            close()
        }
    }

    @objc func close() {
        panel.close()
    }

    @objc private func cancelPressed() {
        button.isEnabled = false
        status.stringValue = "Cancelling…"
        onCancel()
    }
}
