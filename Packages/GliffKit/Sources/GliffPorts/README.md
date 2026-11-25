# GliffPorts

The module for a host's port forwards and the ports it offers. It holds the module's logger.

- **The watcher's command** (`PortWatchCommand`): one shell line, run on a channel, that prints
  the person's listening TCP sockets from `/proc/net/tcp{,6}` and their names from `ss`, a
  frame each time they change, and ends with its channel.
- **Its parser** (`PortListParser`, `PortFrameReader`): reads that untrusted output a chunk at
  a time into `PortFrame`s of `ListeningSocket`s, with caps on frame size and unframed output.
  Numbers come only from the kernel's rows; a name only labels a socket those rows listed.

- **Imports:** Foundation, `os`, `Synchronization` and GliffTransport only. POSIX calls come
  through Foundation's re-export of Darwin.
- **Must not import:** GliffSession, GliffVideo, GliffInput, GliffClipboard, GliffMachines,
  AppKit, UIKit or SwiftUI.
- **Logging:** counts and kinds only. Never a port number, address, destination, process name
  or config line.
