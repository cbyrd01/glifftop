import SwiftUI

/// The text in a field below whose entry Return adds (the machine sheet's port), empty when
/// none: the sheet's default button gives up Return meanwhile, since it would take Return
/// before the field, and its Save keeps the entry.
struct PendingEntryKey: PreferenceKey {
    static let defaultValue = ""

    static func reduce(value: inout String, nextValue: () -> String) {
        if value.isEmpty { value = nextValue() }
    }
}

extension View {
    /// The default button, unless `pending`: then Return goes to the field holding the entry.
    func defaultAction(unless pending: Bool) -> some View {
        keyboardShortcut(pending ? nil : .defaultAction)
    }
}
