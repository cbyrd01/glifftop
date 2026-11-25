import SwiftUI

/// Connection ▸ Show All Monitors: every monitor of the key window's host, as tabs of its group
/// or as windows of their own (`SessionModel+Monitors`). Off unless the window streams over a
/// live link with nothing listing; Show as Tabs also while the window shows one of its sheets,
/// as New Tab is.
struct ShowAllMonitorsMenu: View {
    let model: SessionModel?
    let open: (TabRequest) -> Void

    var body: some View {
        Menu("Show All Monitors") {
            Button("Show as Tabs") { model?.showAllMonitors(asTabs: true, open: open) }
                .disabled(model?.canShowAllMonitors != true || model?.showsSheet == true)
            Button("Show as Windows") { model?.showAllMonitors(asTabs: false, open: open) }
                .disabled(model?.canShowAllMonitors != true)
        }
    }
}
