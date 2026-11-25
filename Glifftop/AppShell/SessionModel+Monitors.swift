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
/// mirror of its own (`MonitorPlanning`), in tabs of the window's group or in windows behind it.
extension SessionModel {
    /// Whether Show as Tabs or Show as Windows can run: the window streams over a live link,
    /// with a destination, nothing listing, and the app not quitting.
    var canShowAllMonitors: Bool {
        phase == .streaming && !isInterrupted && !isReconnecting && destination != nil
            && !screenList.isListing && !quitting
    }

    /// Lists the host's monitors afresh (View ▸ Screen's list too), then opens each one no
    /// window shows, by name, with this window's options; an ended window of one starts again in
    /// place. `open` opens a window for a request. The answer is dropped if the window no
    /// longer streams that destination by then.
    func showAllMonitors(asTabs: Bool, open: @escaping (TabRequest) -> Void) {
        guard canShowAllMonitors, let destination else { return }
        screenList.list(host: destination.value) { [weak self] answer in
            guard let self else { return }
            guard phase == .streaming, self.destination == destination else { return }
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
            var opened = 0
            for opening in openings {
                if opening.inPlace, let ended = OpenSessions.shared.ended(opening.name, on: destination) {
                    ended.start(destination, screen: .named(opening.name))
                    continue
                }
                let start = WindowStart(host: host, options: opening.options, source: source)
                open(
                    TabRequest(
                        tabOf: asTabs ? source : nil, alone: !asTabs, host: host, start: start,
                        // A tab whose group shows a sheet opens alone: cascaded too.
                        place: WindowPlace(step: opened)))
                opened += 1
            }
            logger.info(
                "showing all monitors: \(opened, privacy: .public) opened, \(openings.count - opened, privacy: .public) in place"
            )
        }
    }
}
