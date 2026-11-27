import Carbon
import Foundation
import GliffInput
import os

/// The Mac's keyboard: the selected layout as the keymap text a Keymap carries, and
/// whether the keyboard is ISO (whose two keys macOS reports swapped, `MacKeyCode.positional`).
enum InputSource {
    /// Posted (distributed) when the selected keyboard layout changes.
    static let changed = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    private static let logger = Logger(subsystem: "io.github.cbyrd01.Glifftop", category: "GliffInput")

    static func currentKeymap() -> String {
        let layout = currentLayout()
        logger.info("keymap \(layout.symbols, privacy: .public)")
        return XKBKeymap.text(for: layout)
    }

    /// Whether keyboard type `type` (an event's own, else the last keyboard used) is ISO.
    static func isISOKeyboard(type: Int64? = nil) -> Bool {
        let type = type.map { Int16(truncatingIfNeeded: $0) } ?? Int16(LMGetKbdType())
        return KBGetLayoutType(type) == PhysicalKeyboardLayoutType(kKeyboardISO)
    }

    private static func currentLayout() -> XKBLayout {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return KeyboardLayoutTable.fallback }
        let id = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
        return KeyboardLayoutTable.layout(forInputSource: id)
    }
}
