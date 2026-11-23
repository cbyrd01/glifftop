#if DEBUG
    import GliffSession
    import SwiftUI

    /// Debug ▸ Protocol Inspector (⌥⌘I): for each open window, titled as its tab, the frames
    /// its session sent and received, per type (count, bytes, last seen, per second), and the
    /// last 200. Refreshed once a second, never per message; Pause holds what it shows.
    struct InspectorView: View {
        private struct Section: Identifiable {
            let id: ObjectIdentifier
            let title: String
            let rows: [ProtocolTally.Row]
            let recent: [ProtocolEvent]
            let now: ContinuousClock.Instant
        }

        @State private var sections: [Section] = []
        @State private var paused = false

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if sections.isEmpty {
                        Text("No sessions are open.").foregroundStyle(.secondary)
                    }
                    ForEach(sections) { section in
                        GroupBox(section.title) { content(section) }
                    }
                }
                .padding()
            }
            .frame(minWidth: 520, minHeight: 320)
            .toolbar {
                Toggle("Pause", systemImage: "pause", isOn: $paused)
                Button("Clear", systemImage: "trash") {
                    InspectorModel.shared.clear()
                    refresh()
                }
            }
            .task {
                while !Task.isCancelled {
                    if !paused { refresh() }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        private func content(_ section: Section) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 2) {
                    GridRow {
                        Text("Type").gridColumnAlignment(.leading)
                        Text("Direction").gridColumnAlignment(.leading)
                        Text("Count")
                        Text("Bytes")
                        Text("Last Seen")
                        Text("Per Second")
                    }
                    .font(.caption.bold())
                    ForEach(section.rows, id: \.key) { row in
                        GridRow {
                            Text(row.type)
                            Text(row.direction == .sent ? "Sent" : "Received")
                            Text(row.count, format: .number)
                            Text(Int64(row.bytes), format: .byteCount(style: .binary))
                            Text(ago(row.last, now: section.now))
                            Text(row.perSecond, format: .number)
                        }
                        .monospacedDigit()
                    }
                }
                DisclosureGroup("Last \(section.recent.count) Messages") {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(section.recent.enumerated().reversed()), id: \.offset) { _, event in
                            Text(line(event, now: section.now)).font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func ago(_ time: ContinuousClock.Instant, now: ContinuousClock.Instant) -> String {
            ((now - time) / .seconds(1)).formatted(.number.precision(.fractionLength(1))) + " s ago"
        }

        private func line(_ event: ProtocolEvent, now: ContinuousClock.Instant) -> String {
            let arrow = event.direction == .sent ? "↑" : "↓"
            return "\(arrow) \(event.type)  \(event.bytes) B  \(ago(event.time, now: now))"
        }

        private func refresh() {
            let tallies = OpenSessions.shared.models.map { ($0, InspectorModel.shared.tally(for: $0)) }
            // After the tallies: no frame is newer than now.
            let now = ContinuousClock.now
            sections = tallies.map { model, tally in
                Section(
                    id: ObjectIdentifier(model), title: model.tabTitle, rows: tally.rows(now: now),
                    recent: tally.recent, now: now)
            }
        }
    }

    extension ProtocolTally.Row {
        fileprivate var key: String { "\(direction == .sent ? "↑" : "↓")\(type)" }
    }
#endif
