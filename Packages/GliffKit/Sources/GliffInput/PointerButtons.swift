/// Mac mouse buttons (`NSEvent.buttonNumber`) to evdev button codes: left, right, middle
/// (`BTN_LEFT`, `BTN_RIGHT`, `BTN_MIDDLE`), then back, forward and the extra buttons
/// (`BTN_SIDE` on), as upstream's `BTN_LEFT + n`, up to `BTN_TASK`. Past that is no longer a
/// mouse button (the joystick range): nothing is sent.
public enum PointerButtons {
    public static func code(forButtonNumber number: Int) -> UInt32? {
        (0...7).contains(number) ? 0x110 + UInt32(number) : nil
    }
}
