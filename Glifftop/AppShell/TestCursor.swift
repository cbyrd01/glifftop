#if DEBUG
    import GliffInput
    import GliffProtocol
    import GliffSession

    /// Debug ▸ Test Cursor Shape: a crosshair that can't be mistaken for the Mac's arrow, shown in
    /// place of the session's shapes (Hyprland 0.56.2 shares only blank ones), so the remote
    /// cursor's handling can be checked by hand.
    enum TestCursor {
        private static let side = 32
        private static let hotspot = 16

        /// The crosshair, published once: 2-pixel black lines through the hotspot, each edged
        /// with a white pixel, the rest clear.
        static let slot: CursorSlot = {
            let slot = CursorSlot()
            slot.publish(image)
            return slot
        }()

        private static var image: CursorImage? {
            var bgra = [UInt8](repeating: 0, count: side * side * 4)
            for y in 0..<side {
                for x in 0..<side {
                    let across = min(abs(x - hotspot + 1), abs(x - hotspot))
                    let down = min(abs(y - hotspot + 1), abs(y - hotspot))
                    let distance = min(across, down)
                    guard distance <= 1 else { continue }
                    // Black on the line itself, white on its edge; opaque, so premultiplied as is.
                    let value: UInt8 = distance == 0 ? 0 : 255
                    let i = (y * side + x) * 4
                    bgra.replaceSubrange(i..<i + 4, with: [value, value, value, 255])
                }
            }
            let shape = CursorShape(
                id: 0, width: UInt32(side), height: UInt32(side), hotX: Int32(hotspot), hotY: Int32(hotspot),
                argbLength: UInt32(bgra.count))
            return CursorImage(shape, payload: bgra)
        }
    }
#endif
