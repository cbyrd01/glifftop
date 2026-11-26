import SwiftUI

/// Whether a field below holds an entry Return adds (the machine sheet's port): the sheet's
/// default button gives up Return meanwhile, since it would take Return before the field.
struct PendingEntryKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// The default button, unless `pending`: then Return goes to the field holding the entry.
    func defaultAction(unless pending: Bool) -> some View {
        keyboardShortcut(pending ? nil : .defaultAction)
    }
}
