import GliffInput
import SwiftUI

/// The reminder shown for a few seconds when input is captured (Integrated) or the pointer is
/// confined (Capture): how to get it back. Glass on this capsule only, never on the video
/// under it.
struct InputHintView: View {
    let mode: CaptureMode

    var body: some View {
        Text(text)
            .overPictureCapsule()
    }

    private var text: String {
        switch mode {
        case .integrated: "⌘ shortcuts work over the toolbar · Shift+Esc releases input"
        case .confined: "Shift+Esc frees the pointer and keyboard"
        }
    }
}

extension View {
    /// A short message over the picture's bottom edge: callout text on a glass capsule (never
    /// glass on the video under it).
    func overPictureCapsule() -> some View {
        font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
    }
}
