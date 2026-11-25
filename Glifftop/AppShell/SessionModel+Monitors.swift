import Foundation
import GliffMachines
import GliffSession
import GliffTransport
import os

/// One of Show All Monitors' alerts on the window, with OK.
struct MonitorsAlert {
    let title: String
    var message: String?
}

private let logger = Logger(subsystem: "me.cbyrd.Glifftop", category: "monitors")

/// Connection ▸ Show All Monitors: every monitor of the window's host not shown yet, each as a
/// mirror of its own (`MonitorPlanning`), in tabs of the window's group or in windows behind it:
/// cascaded from it, or on the Mac's displays in the host's order (`MonitorPlacement`).
extension SessionModel {
    /// Whether Show as Tabs or Show as Windows can run: the window streams over a live link,
    /// with a destination, nothing listing, and the app not quitting.
    var canShowAllMonitors: Bool { streamsOverLiveLink && destination != nil && !screenList.isListing }

    /// The window streams over a live link, and the app isn't quitting.
    private var streamsOverLiveLink: Bool {
        phase == .streaming && !isInterrupted && !isReconnecting && !quitting
    }

    /// Lists the host's monitors afresh (View ▸ Screen's list too), then opens each one no
    /// window shows, by name, with this window's options; an ended window of one starts again in
    /// place. `open` opens a window for a request. The answer is dropped if the window no
    /// longer streams that destination over a live link by then.
    func showAllMonitors(asTabs: Bool, open: @escaping (TabRequest) -> Void) {
        guard canShowAllMonitors, let destination else { return }
        screenList.list(host: destination.value) { [weak self] answer in
            guard let self else { return }
            guard streamsOverLiveLink, self.destination == destination else { return }
            switch answer {
            case .cancelled: break
            case .failed(let reason):
                monitorsAlert = MonitorsAlert(title: "Couldn't list \(host)'s monitors", message: reason)
            case .listed(let screens): show(screens, on: destination, asTabs: asTabs, open: open)
            }
        }
    }

    /// Starts a window's session from `start` as it opens (Show All Monitors' windows).
    func connect(_ start: WindowStart) {
        do throws(SSHTargetError) {
            try connect(to: start.host, options: start.options, screenIsOwn: start.screenIsOwn)
        } catch {
            // The host was valid in the window it came from; its reason could name it.
            logger.error("a monitor's window could not start: invalid destination")
        }
    }

    private func show(
        _ screens: [RemoteScreen], on destination: SSHTarget, asTabs: Bool, open: (TabRequest) -> Void
    ) {
        guard let source = tabGroup?.window else {
            logger.error("showing all monitors: the window's number isn't known yet")
            return
        }
        let shown = OpenSessions.shared.shown(for: destination)
        switch MonitorPlanning.plan(listed: screens, shown: shown, source: currentOptions) {
        case .empty:
            monitorsAlert = MonitorsAlert(title: "\(host) has no monitors to show.")
        case .allShown:
            monitorsAlert = MonitorsAlert(title: "All of \(host)'s monitors are already shown.")
        case .open(let openings):
            let slots =
                asTabs || !AppSettings.placesMonitorWindows
                ? [:] : placeInHostOrder(openings, listed: screens, on: destination, source: source)
            var opened = 0
            for opening in openings {
                let start = WindowStart(host: host, options: opening.options, source: source)
                if opening.inPlace, let ended = OpenSessions.shared.ended(opening.name, on: destination) {
                    ended.connect(start)
                    continue
                }
                open(
                    TabRequest(
                        tabOf: asTabs ? source : nil, alone: !asTabs, host: host, start: start,
                        // A tab whose group shows a sheet opens alone: cascaded too.
                        place: slots[opening.name].map { WindowPlace(display: $0.display, step: $0.step) }
                            ?? WindowPlace(step: opened)))
                opened += 1
            }
            logger.info(
                "showing all monitors: \(opened, privacy: .public) opened, \(openings.count - opened, privacy: .public) in place"
            )
        }
    }

    /// Each monitor's slot on the Mac's displays, in the host's order, counting the windows
    /// already showing one (a tab group once, as its first such tab); the key window (`source`)
    /// moved to its own when it may.
    private func placeInHostOrder(
        _ openings: [MonitorOpening], listed: [RemoteScreen], on destination: SSHTarget, source: Int
    ) -> [String: Slot] {
        let inPlace = Set(openings.filter(\.inPlace).map(\.name))
        var windows = openings.filter { !$0.inPlace }.map { PlacedWindow.new(monitor: $0.name) }
        // The key window's group counts as the key window.
        var counted = Set(tabGroup?.tabs ?? [source])
        for model in OpenSessions.shared.models where model.destination == destination {
            let tabs = model.tabGroup?.tabs ?? []
            guard counted.isDisjoint(with: tabs), let monitor = model.placedMonitor(restarting: inPlace)
            else { continue }
            counted.formUnion(tabs)
            windows.append(.stays(monitor: monitor))
        }
        // Without a mirror size it couldn't be fitted on its new display: it stays.
        let movable = !sharesWindow && snapshot.mirrorSize != nil && WindowPlacement.isMovable(source)
        windows.append(.key(monitor: mirroredMonitor, movable: movable))
        let slots = MonitorPlacement.slots(
            hostOrder: MonitorPlanning.hostOrder(listed).map(\.name), windows: windows,
            displays: WindowPlacement.displays())
        if let monitor = mirroredMonitor, let slot = slots[monitor], slot.fits, let size = snapshot.mirrorSize
        {
            let statusBar = UserDefaults.standard.bool(forKey: AppSettings.showsStatusBarKey)
            WindowPlacement.move(
                source, display: slot.display, step: slot.step, view: size,
                extraHeight: statusBar ? StatusBar.height : 0)
        }
        return slots
    }

    /// The monitor this window shows where it is: a live mirror's, or an ended named mirror's
    /// that starts again in place (`restarting`).
    private func placedMonitor(restarting: Set<String>) -> String? {
        if canDisconnect { return mirroredMonitor }
        guard case .named(let name) = screenChoice, restarting.contains(name) else { return nil }
        return name
    }
}
