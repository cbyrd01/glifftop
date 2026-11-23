# GliffTransport

Owns the byte stream to a gliff-server: the `Transport` seam, and ssh.

- **Imports:** Foundation, plus the platform layers under it: `os` (Logger), `Synchronization`
  (Mutex, Swift's standard library); signals come through Foundation. Must not import GliffSession,
  GliffVideo, AppKit or UIKit.
- **Seam:** `Transport.connect()` gives a `ByteConnection` (`incoming` chunks, `write`,
  `close`). The session only sees this, so tests run against `tools/fake-server` instead
  of ssh.
- **ssh:** `SSHTarget` checks what was typed (trimmed; no leading dash, whitespace,
  control characters, ssh_config wildcards or the shell characters ssh refuses),
  `SSHCommand` builds the argv (`BatchMode=yes`,
  `StrictHostKeyChecking=yes` first so nothing can relax it, `IPQoS=ef`, keepalives that
  end a dead link after about a minute, a 10 s `ConnectTimeout` for a host that drops
  packets, added only when `ssh -G` shows the person's ssh_config sets no timeout and no
  proxy (`SSHConnectTimeout`), `--` before the target, server arguments
  shell-quoted for the remote login shell), and `SSHErrorClassifier` turns ssh's stderr
  into a `ConnectFailure` with a plain-language `message`.
- **Shared connections:** `HostConnection` is one signed-in connection to a host that runs
  shell commands as channels (`ByteConnection`s); a system ssh ControlMaster or an embedded ssh
  can each be one. `HostConnections` (an actor) keeps one per destination as typed, held by
  `HostLease`s: everyone asking while one opens waits for that one sign-in; it closes 10 s after
  its last lease ends; a failed sign-in answers that destination for 10 s unless a connection
  there has room; a connection takes at most 10 leases (sshd's `MaxSessions`), and one that
  refuses a channel takes no more, its lease moving to a further connection; a lost connection is
  forgotten at once, so the next lease opens anew; `closeAll()` ends them all and cancels anyone
  waiting.
- **Screens:** `ScreenChoice` is what a session shows (the focused monitor, one by name,
  or a virtual screen) as gliff-server's arguments. `ScreenListParser` reads the host's
  `hyprctl -j monitors` as untrusted input into `RemoteScreen`s: at most 1 MiB, names only
  `[A-Za-z0-9._:-]` (1–64), a description from make and model only (never the serial
  number), rotated monitors' sides swapped, disabled ones and gliff-server's own virtual
  screens (`gliff-<pid>`, gone when their session ends) left out. `ScreenListCommand` is
  the one-shot ssh for Get Screens: `SSHCommand`'s options, then a fixed one-line `sh -c`
  script that tries each Hyprland instance as gliff-server does (the session's own, then the
  newest whose socket answers) and prints `hyprctl -j monitors`. `ScreenLister` (macOS) runs
  it: stdout up to 1 MiB, a 60 s limit (room for a 1Password approval), failures in
  `SSHErrorClassifier`'s words; too much, too late or cancelled, it ends the process at once
  (`ProcessConnection.terminate`), and it answers only once the process is reaped. Both it
  and the `ssh -G` probe read a one-shot program's output through `ProcessOutput`.
- **Processes (macOS only):** `ProcessTransport` runs a program and speaks over its
  stdin/stdout through `DispatchIO` (never blocking the cooperative pool); it keeps stderr's
  last 16 KiB for the classifier. `SystemSSHTransport` is that with `/usr/bin/ssh` and
  `SSHCommand.arguments`, after the `ssh -G` probe; cancelled by then, it throws
  `.cancelled` without starting ssh, as `ProcessOutput` does. `close()` closes stdin, waits 2 s, SIGTERMs, waits 1 s, SIGKILLs,
  and returns once the process is reaped; it also runs when the reader of `incoming` goes
  away.
