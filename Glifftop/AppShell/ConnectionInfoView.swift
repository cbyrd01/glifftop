import GliffSession
import SwiftUI

/// Connection Info (⌘I, the toolbar's ⓘ): the live numbers and the stream, in a popover.
struct ConnectionInfoView: View {
    let model: SessionModel

    var body: some View {
        Group {
            if let picture = model.picture {
                StatsView(host: model.host, stream: picture.stream, stats: model.snapshot.stats)
            } else {
                Text("No picture yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}
