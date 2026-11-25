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
- **Trust:** only the person's own scripts run, each approved once with its full text in front
  of them. A script travels on the channel's stdin, never on a command line. No script, name,
  output byte, exported value, destination, path, token or key ever reaches `os.Logger`, an
  error's text or a description.
- **Imports:** Foundation, GliffTransport, `os` and `Synchronization` only. Must not import
  GliffSession, GliffMachines, GliffClipboard, GliffVideo, GliffInput, SwiftUI, AppKit, UIKit,
  CryptoKit or Security. It compiles for iOS.
