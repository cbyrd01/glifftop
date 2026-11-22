import SwiftUI

extension Binding<Bool> {
    /// A switch that asks first when turned on (`confirming` shows the alert, whose button
    /// sets `value`) and turns off at once.
    static func askingFirst(_ value: Binding<Bool>, confirming: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue },
            set: { on in
                if on { confirming.wrappedValue = true } else { value.wrappedValue = false }
            })
    }
}

extension View {
    /// The question before Share the clipboard turns on, in Settings and the toolbar alike.
    func shareClipboardConfirmation(isPresented: Binding<Bool>, share: @escaping () -> Void) -> some View {
        alert("Share the clipboard with the remote computer?", isPresented: isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Share", action: share)
        } message: {
            Text(
                "While Glifftop is in front, anything you copy on this Mac is sent to the remote computer, where its apps can read it and its clipboard tools may keep it. Copies made on the remote computer come to this Mac. Passwords are sent only with Include passwords on."
            )
        }
    }
}
