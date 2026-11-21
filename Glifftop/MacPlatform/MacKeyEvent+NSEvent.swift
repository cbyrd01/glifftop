import AppKit
import GliffInput

extension MacKeyEvent {
    /// A key event as values, its code the key's position (an ISO keyboard's two swapped keys
    /// put back); nil for anything but key down, key up and a modifier change.
    init?(_ event: NSEvent) {
        let kind: Kind
        switch event.type {
        case .keyDown: kind = .down(isRepeat: event.isARepeat)
        case .keyUp: kind = .up
        case .flagsChanged: kind = .flagsChanged
        default: return nil
        }
        // The keyboard that sent it: with two attached, the last one used may be the other.
        let type = event.cgEvent?.getIntegerValueField(.keyboardEventKeyboardType)
        let code = MacKeyCode.positional(event.keyCode, isISO: InputSource.isISOKeyboard(type: type))
        self.init(keyCode: code, kind: kind, flags: event.modifierFlags.rawValue)
    }
}
