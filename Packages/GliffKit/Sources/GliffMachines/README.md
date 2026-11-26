# GliffMachines

Owns the saved machines and their options: `Machine` (a name, the ssh destination, whether
it's a favourite, when it last connected) and `MachineOptions` (the screen, a virtual screen's
text size and resolution, Scale to Fit, reconnect, and the clipboard's sharing: nil follows
Settings'), and `MachineList`, which keeps each
destination once in the order the list shows (favourites, then the most recent, then by
name) and reads and writes them as JSON.

- An entry that can't be read, or a second with the same destination, is skipped and the
  rest kept; the next store drops it for good. An option missing or unreadable takes its
  default. Saving a machine with another's destination replaces that one. A stored monitor name must be one Get Screens would offer
  and not a session's virtual screen (`ScreenChoice`'s decoding), as it becomes a server
  argument.
- `TabPlanning`: a new tab to a machine open elsewhere starts as a virtual screen, and a
  window's tabs are titled with their machine's name, numbered among the machine's tabs; a
  mirror's title names its monitor once known ("omarchy · DP-3"), numbered only from a
  second mirror whose title reads the same, and not counted among the machine's tabs.
- Window plans for a machine's monitors (Show All Monitors). `MonitorPlanning`: the host's
  monitors in host order (by position left to right, then top to bottom, then by name; those
  without a position last, by name), and which to open: every listed monitor by name, those
  live sessions show skipped (a Focused Monitor mirror not yet named shows the focused
  one), at most 16 (the list is untrusted), an ended window of one
  started again in place, each with the
  source window's options and the screen its monitor. `MonitorPlacement`: with the placement
  option on, which Mac display each monitor's window goes on, ordering only: displays left
  to right (of two with the same left edge, the higher first), the host's first monitor on
  the first (by its place in the host's order, whether or not every monitor has a window),
  those past the last display cascading on it, each window on a display a cascade step
  (windows that stay counted); only new windows and a movable key window move, a monitor
  shown twice takes the key window's place, and a virtual-screen key window takes no slot. Plain rectangles: no AppKit.
- `ReconnectScreen`: what a window's reconnect (or Try Again) asks the server for. A Focused
  Monitor mirror asks for the monitor its last Focused Monitor session streamed, by name (a
  name a monitor's could be), so the reconnect restores its picture though the host's focus
  has moved; the window's choice stays Focused Monitor. A session that ends with that monitor
  missing is started again at once, asking for the focused monitor (its end not shown, nor
  counted as a try). Once another choice streams or the person starts a connection, it asks
  for the focused monitor too. Any other choice asks for itself. Show All Monitors counts a reconnecting
  Focused Monitor mirror as showing the monitor its try asks for.
- It has no storage of its own: the app keeps the data (in `UserDefaults`).
- Imports Foundation, GliffTransport, GliffSession and GliffClipboard only. Must not import AppKit, UIKit,
  SwiftUI, Observation or GliffVideo.
