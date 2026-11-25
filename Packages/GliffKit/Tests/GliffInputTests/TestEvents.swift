@testable import GliffInput

// Mac key events, key messages and a captured controller, for the `InputController` suites.

func down(_ code: UInt16, _ flags: MacModifierFlags = [], isRepeat: Bool = false) -> MacKeyEvent {
    MacKeyEvent(keyCode: code, kind: .down(isRepeat: isRepeat), flags: flags.rawValue)
}

func up(_ code: UInt16, _ flags: MacModifierFlags = []) -> MacKeyEvent {
    MacKeyEvent(keyCode: code, kind: .up, flags: flags.rawValue)
}

func flags(_ code: UInt16, _ flags: MacModifierFlags = []) -> MacKeyEvent {
    MacKeyEvent(keyCode: code, kind: .flagsChanged, flags: flags.rawValue)
}

func key(_ code: UInt32, _ pressed: Bool) -> InputMessage { .key(code: code, pressed: pressed) }

/// A controller with the window key, the app active and a picture: captured.
func capturedController() -> InputController {
    var controller = InputController(keymap: "k1")
    for event: CaptureEvent in [.windowKey(true), .appActive(true), .picture(true)] {
        _ = controller.capture(event)
    }
    return controller
}
