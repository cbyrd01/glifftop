import SwiftUI

/// What a window is opened for: each request a new window (its own id), in the tab group of
/// window `tabOf` (File ▸ New Tab), alone (File ▸ New Window), or, with neither, in the group of
/// the session window in front (the tab bar's +), if any (the first window has none).
struct TabRequest: Codable, Hashable {
    var id = UUID()
    /// The window number of the window whose tab group it joins.
    var tabOf: Int?
    /// A window of its own, even under System Settings' "Prefer tabs: Always".
    var alone = false
    /// The host the new window's field starts with: the session's it was opened beside.
    var host: String?
}

/// One window (or tab) and its own session: the model it owns, known to `OpenSessions` while
/// open, the menu bar's while key. Closing it ends its session as Disconnect does.
struct SessionWindow: View {
    let request: TabRequest
    @State private var model: SessionModel

    init(request: TabRequest) {
        self.request = request
        let model = SessionModel()
        model.fieldHost = request.host
        _model = State(initialValue: model)
    }

    var body: some View {
        RootView(model: model)
            .focusedSceneValue(\.session, model)
            .background {
                WindowTabbing(tabOf: request.tabOf, alone: request.alone) { [model] in
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
