# GliffMacros

Owns a saved machine's macros: shell scripts Glifftop runs on the host over its shared ssh
connection, before the session, once the screen exists, on demand and at Disconnect.

- `Macro`: a macro's stored fields (`MacroMoment`, `MacroRuns`, `MacroLimits`), with a tolerant
  decoder: a field missing or unreadable takes its moment's default, a script that can't run is
  kept disabled. A name loses control and format characters, its breaks become spaces, and it
  keeps whole characters up to 100 characters and 300 Unicode scalars.
- `MacroText`: the character rules for scripts. Control, format and separator characters are
  refused (but `\n` and `\t`); other characters outside printable ASCII are shown escaped in the
  approval sheet.
- `MacroContext`: a run's `GLIFF_*` variables (moment, reconnect, screen, and the server's
  output once the session exists), each name checked as Get Screens checks one.
  `preview(for:screen:)` is what the editor and the approval sheet show.
- `MacroScript`: the text a run writes on stdin: a first line that defines `glifftop_run` and
  names Glifftop in a comment, `unset` of the wrapper's and the `GLIFF_*` variables, the
  `export` lines (values quoted), the Hyprland lookup, the script, its run, and the line
  `#TOKEN`. The script runs on its own, as the body of `glifftop_run` (which stays defined), so
  its errors give the editor's line numbers. A script that can't run builds nothing.
- `MacroWrapper`: the host side, `sh -c '<wrapper>' glifftop-macro LEN LIMIT TOKEN`. It sends
  its stderr to stdout, runs the text only when all of it arrived, prints a start line and a
  trailer, and ends the run's process group after the trailer, at the limit, or when the
  channel's stdin closes. The Mac keeps stdin open while the script runs, reads to the first
  trailer, then closes the channel.
- `MacroToken`: a run's 32 hex digits from `SystemRandomNumberGenerator`; it never prints
  itself.
- **Trust:** only the person's own scripts run, each approved once with its full text in front
  of them. A script travels on the channel's stdin, never on a command line. No script, name,
  output byte, exported value, destination, path, token or key ever reaches `os.Logger`, an
  error's text or a description.
- **Imports:** Foundation, GliffTransport, `os` and `Synchronization` only. Must not import
  GliffSession, GliffMachines, GliffClipboard, GliffVideo, GliffInput, SwiftUI, AppKit, UIKit,
  CryptoKit or Security. It compiles for iOS.
