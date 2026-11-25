# GliffMachines

Owns the saved machines and their options: `Machine` (a name, the ssh destination, whether
it's a favourite, when it last connected, and its macros: `GliffMacros`' `Macro`, in run
order), `MachineOptions` (the screen, a virtual screen's text size and resolution, Scale to
Fit, reconnect, and the clipboard's sharing: nil follows Settings'), and `MachineList`, which
keeps each destination once in the order the list shows (favourites, then the most recent,
then by name) and reads and writes them as JSON.

- An entry that can't be read, or a second with the same destination, is skipped and the rest
  kept; the next store drops it for good. An option missing or unreadable takes its default.
  Saving a machine with another's destination replaces that one, and its macros, unapproved,
  follow the saved machine's (`macrosAfterSave`, which the sheet validates). A stored monitor
  name must be one Get Screens would offer and not a session's virtual screen
  (`ScreenChoice`'s decoding), as it becomes a server argument.
- Macros are read lossily: a missing or unreadable list is none, an entry that can't be read is
  dropped, as is a repeated id, and past 20 macros or 256 KiB of scripts the first that fit are
  kept; a save keeps them the same way. The machine sheet's save keeps each macro's stored
  approval, never the sheet's copy's, and only while its script and moment are unchanged;
  Always Run (`approve`) stores one only while the script is unchanged and can run.
  `validate(macros:)` is the sheet's check of the limits.
- `TabPlanning`: a new tab to a machine open elsewhere starts as a virtual screen, and a
  window's tabs are titled with their machine's name, numbered from its second tab.
- It has no storage of its own: the app keeps the data (in `UserDefaults`).
- Imports Foundation, GliffTransport, GliffSession, GliffClipboard and GliffMacros only. Must
  not import AppKit, UIKit, SwiftUI, Observation or GliffVideo.
