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
  window's tabs are titled with their machine's name, numbered from its second tab.
- It has no storage of its own: the app keeps the data (in `UserDefaults`).
- Imports Foundation, GliffTransport, GliffSession and GliffClipboard only. Must not import AppKit, UIKit,
  SwiftUI, Observation or GliffVideo.
