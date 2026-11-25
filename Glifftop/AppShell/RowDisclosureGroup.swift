import SwiftUI

/// A disclosure group whose title toggles it as its arrow does. The title is a plain button, so
/// VoiceOver and Full Keyboard Access reach it too, and it fills the row.
struct RowDisclosureGroup<Content: View>: View {
    private let title: LocalizedStringKey
    /// The caller's state, or nil to keep its own.
    private let isExpanded: Binding<Bool>?
    @State private var expandedHere = false
    private let content: Content

    init(
        _ title: LocalizedStringKey, isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        let expanded = isExpanded ?? $expandedHere
        DisclosureGroup(isExpanded: expanded) {
            content
        } label: {
            Button {
                withAnimation { expanded.wrappedValue.toggle() }
            } label: {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}
