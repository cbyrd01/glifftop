import GliffClipboard
import SwiftUI

/// Share the clipboard (`ClipboardSharing`), as the app shows it. Settings' is stored as the two
/// switches `AppSettings` names; Not Shared clears both, so sharing again never brings
/// passwords back unasked.
extension ClipboardSharing {
    var label: String {
        switch self {
        case .off: "Not shared"
        case .shared: "Shared"
        case .withPasswords: "Shared, including passwords"
        }
    }

    /// The toolbar button's tooltip: what it is, and what a click does.
    var help: String {
        switch self {
        case .off: "The clipboard isn't shared. Click to share it."
        case .shared: "The clipboard is shared, without passwords. Click to include passwords."
        case .withPasswords: "The clipboard is shared, passwords too. Click to stop sharing."
        }
    }
}

/// Share the clipboard as stored, for a view: it reads and writes both switches.
@propertyWrapper struct StoredClipboardSharing: DynamicProperty {
    @AppStorage(AppSettings.shareClipboardKey) private var share = false
    @AppStorage(AppSettings.includePasswordsKey) private var includePasswords = false

    var wrappedValue: ClipboardSharing {
        get { ClipboardSharing(share: share, includePasswords: includePasswords) }
        nonmutating set { (share, includePasswords) = (newValue != .off, newValue == .withPasswords) }
    }

    var projectedValue: Binding<ClipboardSharing> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

/// A question before the clipboard sends more: the setting asked for and the one in force when
/// asked. Kept once answered (only `isShown` goes), so the closing alert keeps its words while
/// the setting moves on.
struct ClipboardQuestion: Equatable {
    let level: ClipboardSharing
    let from: ClipboardSharing
    var isShown = true

    var title: String {
        switch (level, from) {
        case (.withPasswords, .shared): "Include passwords?"
        case (.withPasswords, _): "Share the clipboard, including passwords?"
        default: "Share the clipboard with the remote computer?"
        }
    }

    var button: String { level == .withPasswords && from == .shared ? "Include Passwords" : "Share" }

    var message: String {
        let sharing =
            "While Glifftop is in front, anything you copy on this Mac is sent to the remote computer, where its apps can read it and its clipboard tools may keep it. Copies made on the remote computer come to this Mac."
        let passwords = "Copies your password manager marks as concealed will reach the remote computer too."
        switch (level, from) {
        case (.withPasswords, .shared): return passwords
        case (.withPasswords, _): return "\(sharing) \(passwords)"
        default: return "\(sharing) Passwords aren't sent unless you include them."
        }
    }
}

extension Binding<ClipboardSharing> {
    /// A choice that asks first when it would send more (`asking` holds the question; the
    /// alert's button sets the choice) and sends less at once.
    static func askingFirst(_ value: Binding<ClipboardSharing>, asking: Binding<ClipboardQuestion?>)
        -> Binding<ClipboardSharing>
    {
        Binding(
            get: { value.wrappedValue },
            set: { level in
                if value.wrappedValue.sendsLess(than: level) {
                    asking.wrappedValue = ClipboardQuestion(level: level, from: value.wrappedValue)
                } else {
                    value.wrappedValue = level
                }
            })
    }
}

extension View {
    /// The question before the clipboard is shared, or passwords join it, in Settings and the
    /// toolbar alike.
    func clipboardSharingConfirmation(
        _ question: Binding<ClipboardQuestion?>, confirm: @escaping (ClipboardSharing) -> Void
    ) -> some View {
        alert(
            question.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { question.wrappedValue?.isShown ?? false },
                set: { question.wrappedValue?.isShown = $0 }),
            presenting: question.wrappedValue
        ) { question in
            Button("Cancel", role: .cancel) {}
            Button(question.button) { confirm(question.level) }
        } message: { question in
            Text(question.message)
        }
    }
}
