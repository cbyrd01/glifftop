import SwiftUI

/// The reminder shown for a few seconds when input is captured: how to get it back.
/// Glass on this capsule only, never on the video under it.
struct InputHintView: View {
    var body: some View {
        Text("Shift+Esc releases input")
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
    }
}
