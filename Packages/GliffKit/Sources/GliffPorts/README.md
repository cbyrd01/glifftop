# GliffPorts

The module for a host's port forwards and the ports it offers. It holds the module's logger.

- **The watcher's command** (`PortWatchCommand`): one shell line, run on a channel, that prints
  the person's listening TCP sockets from `/proc/net/tcp{,6}` and their names from `ss`, a
  frame each time they change, and ends with its channel.
- **Its parser** (`PortListParser`, `PortFrameReader`): reads that untrusted output a chunk at
  a time into `PortFrame`s of `ListeningSocket`s, with caps on frame size and unframed output.
  Numbers come only from the kernel's rows; a name only labels a socket those rows listed.
- **What is offered** (`PortFilter`, `RemotePort`): the person's own ports, one entry each,
  split into available and other, never gliff's own server or sshd; a forward goes where the
  socket listens.
- **Which Mac port** (`LocalPortChooser`): the remembered or remote number when free, else
  counting up, else one the system picks; the loopback check is injected. `start(for:)` is
  where it starts with nothing remembered.
- **What is forwarded unasked** (`AutomaticPortPolicy`): only with names, never a database or
  cache port.
- **A host's forwards** (`HostPorts`, `PortsRegistry`, `PortsHold`, `PortsSnapshot`): one actor
  per destination while a window holds it, on a passive lease it never opens; forwards wait
  through a reconnect, move when their Mac port is taken, and are cancelled 10 s after the
  last hold ends.
- **The watcher and offers** (`HostPorts+Watcher`, `HostPorts+Offers`, `PortNotice`): the
  watcher runs on a spare place that yields to a tab, restarts with a back-off and stops after
  five failures in a row; a port that appears after the first frame is offered with a notice,
  or forwarded under the automatic setting (the registry's) until frames have shown it gone
  10 s. A frame cut at 64 sockets shows no port gone. Only a forward to the host itself
  (`localhost` or a loopback address) takes one of its ports; the ports go from view when the
  watcher stops, and an offer not answered comes back with its port. Detection is idle while
  not attached, and stopped only once the watcher gave up.
- **The popover's text** (`PortsText`): a forward's Mac address (`localhost:P` on both
  loopbacks, `127.0.0.1:P` on IPv4 alone), the page it opens, a destination (the port alone on
  the host itself), the Mac port a moved forward had, and a forward's row by its id.
- **The notice a window shows** (`ShownNotice`): the last new one (an offer naming a port no
  earlier offer named, or a forward's notice not there before), else the one shown while it
  lasts, else the last; nothing is new in a window's first snapshot.

- **Imports:** Foundation, `os`, `Synchronization` and GliffTransport only. POSIX calls come
  through Foundation's re-export of Darwin.
- **Must not import:** GliffSession, GliffVideo, GliffInput, GliffClipboard, GliffMachines,
  AppKit, UIKit or SwiftUI.
- **Logging:** counts and kinds only. Never a port number, address, destination, process name
  or config line.
