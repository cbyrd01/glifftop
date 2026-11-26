import SwiftUI

/// The reminder shown for a few seconds when input is captured: how to get it back.
/// Glass on this capsule only, never on the video under it.
struct InputHintView: View {
    var body: some View {
        Text("Shift+Esc releases input")
            .overPictureCapsule()
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
