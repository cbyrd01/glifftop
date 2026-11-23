import SwiftUI

/// What a window is opened for: each request a new window (its own id), in the tab group of
/// window `tabOf` (File ▸ New Tab) or alone.
struct TabRequest: Codable, Hashable {
    var id = UUID()
    /// The window number of the window whose tab group it joins.
    var tabOf: Int?
}

/// One window (or tab) and its own session: the model it owns, known to `OpenSessions` while
/// open, the menu bar's while key. Closing it ends its session as Disconnect does.
struct SessionWindow: View {
    let request: TabRequest
    @State private var model = SessionModel()

    var body: some View {
        RootView(model: model)
            .focusedSceneValue(\.session, model)
            .background {
                WindowTabbing(tabOf: request.tabOf) { [model] in
                    model.tabGroup = $0
                } closed: { [model] in
                    OpenSessions.shared.close(model)
                }
            }
            .onAppear {
                OpenSessions.shared.add(model)
                model.capture.onTabChord = OpenSessions.shared.selectTab
            }
    }
}
