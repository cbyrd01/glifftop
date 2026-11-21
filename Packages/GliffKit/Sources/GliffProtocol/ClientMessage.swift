/// A message to gliff-server (upstream `ClientMsg`). Case order is not the wire order; the
/// variant indices are in `encode(to:)`, and the clipboard ones in `ClipboardMessage.Kind`.
public enum ClientMessage: Equatable, Sendable {
    case hello(version: UInt16, keymap: String, caps: ClientCaps)
    /// `scale` is an `f32` on the wire.
    case resize(width: UInt32, height: UInt32, scale: Float)
    /// `keycode` is an evdev code.
    case key(keycode: UInt32, pressed: Bool)
    case pointerMotion(x: Double, y: Double)
    case pointerButton(button: UInt32, pressed: Bool)
    /// `discrete` is the wheel's click count, nil for smooth scrolling.
    case pointerAxis(axis: Axis, value: Double, discrete: Int32?, stop: Bool)
    /// Exactly one per `VideoFrame`, sent after the decode's GPU work.
    case frameAck(frameID: UInt64, decodedAtMilliseconds: UInt64)
    case requestKeyframe
    case clipboard(ClipboardMessage)
    case ping(t: UInt64)
    case bye
    case keymap(String)
    case pong(t: UInt64)

    /// The frame body: this message's CBOR, byte-for-byte what upstream's client sends.
    public var encoded: [UInt8] {
        var writer = CBORWriter()
        encode(to: &writer)
        return writer.bytes
    }

    func encode(to w: inout CBORWriter) {
        switch self {
        case .hello(let version, let keymap, let caps):
            w.variant(0, fieldCount: 3)
            w.unsigned(UInt64(version))
            w.text(keymap)
            caps.encode(to: &w)
        case .resize(let width, let height, let scale):
            w.variant(1, fieldCount: 3)
            w.unsigned(UInt64(width))
            w.unsigned(UInt64(height))
            w.float32(scale)
        case .key(let keycode, let pressed):
            w.variant(2, fieldCount: 2)
            w.unsigned(UInt64(keycode))
            w.bool(pressed)
        case .pointerMotion(let x, let y):
            w.variant(3, fieldCount: 2)
            w.float64(x)
            w.float64(y)
        case .pointerButton(let button, let pressed):
            w.variant(4, fieldCount: 2)
            w.unsigned(UInt64(button))
            w.bool(pressed)
        case .pointerAxis(let axis, let value, let discrete, let stop):
            w.variant(5, fieldCount: 4)
            w.wireEnum(axis)
            w.float64(value)
            if let discrete { w.signed(Int64(discrete)) } else { w.null() }  // a middle None is null
            w.bool(stop)
        case .frameAck(let frameID, let decodedAt):
            w.variant(6, fieldCount: 2)
            w.unsigned(frameID)
            w.unsigned(decodedAt)
        case .requestKeyframe:
            w.variant(7, fieldCount: 0)
        case .clipboard(let message):
            message.encode(to: &w, variant: message.kind.clientVariant)
        case .ping(let t):
            w.variant(11, fieldCount: 1)
            w.unsigned(t)
        case .bye:
            w.variant(12, fieldCount: 0)
        case .keymap(let keymap):
            w.variant(15, fieldCount: 1)
            w.text(keymap)
        case .pong(let t):
            w.variant(16, fieldCount: 1)
            w.unsigned(t)
        }
    }
}
