import AppKit

/// The displays' size in pixels, for the largest stream worth asking the server for.
enum DisplayMetrics {
    /// The widest and tallest of the attached displays, in pixels (points × backing scale), so
    /// the stream fits whichever display the window is moved to.
    static func largestDisplayPixels() -> (width: UInt32, height: UInt32) {
        let sizes = NSScreen.screens.map { $0.convertRectToBacking($0.frame).size }
        // No display at all (headless): a 4K stream.
        guard let width = sizes.map(\.width).max(), let height = sizes.map(\.height).max() else {
            return (3840, 2160)
        }
        return (UInt32(clamping: Int(width.rounded())), UInt32(clamping: Int(height.rounded())))
    }
}
