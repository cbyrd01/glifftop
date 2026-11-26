import SwiftUI

/// The text in a field whose entry Return adds (the machine sheet's port), empty when none:
/// the sheet's default button gives Return to the entry's Add meanwhile, since the default
/// button takes Return before the field, and its Save keeps the entry.
struct PendingEntryKey: PreferenceKey {
    static let defaultValue = ""

    static func reduce(value: inout String, nextValue: () -> String) {
        if value.isEmpty { value = nextValue() }
    }
}

extension View {
    /// The default button while `isDefault`: a sheet's gives Return to an entry's own button
    /// while the entry is typed.
    func defaultAction(when isDefault: Bool) -> some View {
        keyboardShortcut(isDefault ? .defaultAction : nil)
    }
}
