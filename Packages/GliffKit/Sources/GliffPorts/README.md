# GliffPorts

The module for a host's port forwards and the ports it offers. It holds the module's logger.

- **Imports:** Foundation, `os`, `Synchronization` and GliffTransport only. POSIX calls come
  through Foundation's re-export of Darwin.
- **Must not import:** GliffSession, GliffVideo, GliffInput, GliffClipboard, GliffMachines,
  AppKit, UIKit or SwiftUI.
- **Logging:** counts and kinds only. Never a port number, address, destination, process name
  or config line.
