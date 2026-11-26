# GliffMachines

Owns the saved machines and their options: `Machine` (a name, the ssh destination, whether
it's a favourite, when it last connected) and `MachineOptions` (the screen, a virtual screen's
text size and resolution, Scale to Fit, reconnect, the clipboard's sharing: nil follows
Settings', and `SavedForward`, the ports it forwards when connected), and `MachineList`, which
keeps each
destination once in the order the list shows (favourites, then the most recent, then by
name) and reads and writes them as JSON.

- An entry that can't be read, or a second with the same destination, is skipped and the
  rest kept; the next store drops it for good. An option missing or unreadable takes its
  default. Saving a machine with another's destination replaces that one. A stored monitor name must be one Get Screens would offer
  and not a session's virtual screen (`ScreenChoice`'s decoding), as it becomes a server
  argument. A saved forward's destination must be `localhost` or an IP literal (kept in one
  spelling) and its ports in range; one that isn't, or repeats an earlier one, is dropped and
  the rest kept. A window's record never changes its machine's forwards. A forward to a name
  only the ssh_config gives can't be saved; `toggleForwardWhenConnected` adds a forward with
  its Mac port, or removes it; `typedPort` reads a typed port on the host itself
  (none, not a port, kept already, or new), which `addForwardWhenConnected` adds and
  `keeping(typed:)` keeps on Save.
- `TabPlanning`: a new tab to a machine open elsewhere starts as a virtual screen, and a
  window's tabs are titled with their machine's name, numbered from its second tab.
- It has no storage of its own: the app keeps the data (in `UserDefaults`).
- Imports Foundation, GliffTransport, GliffSession and GliffClipboard only. Must not import AppKit, UIKit,
  SwiftUI, Observation or GliffVideo.
