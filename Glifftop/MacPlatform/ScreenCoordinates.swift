import AppKit

/// Quartz's global display coordinates (origin at the main display's top-left, `y` growing
/// down, as `CGEvent.location` and `CGWarpMouseCursorPosition` use) and AppKit's screen
/// coordinates (origin at the main display's bottom-left, `y` growing up).
enum ScreenCoordinates {
    /// The height both flip about: the main display's (the first screen's) frame.
    @MainActor private static var mainMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    @MainActor static func appKit(fromGlobal point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: mainMaxY - point.y)
    }

    @MainActor static func global(fromAppKit point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainMaxY - point.y)
    }
}
