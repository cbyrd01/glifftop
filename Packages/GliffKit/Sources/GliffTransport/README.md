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
  its last lease ends; a sign-in that asked and failed (the agent or the key refused, no
  approval in a minute) answers that destination for 10 s unless a connection there has room,
  and a `fresh` lease (an attempt the person starts) asks again; an open nobody has waited for
  in 1 s is cancelled (so a session that starts as a listing stops shares its sign-in); a connection takes at most 10 leases (sshd's `MaxSessions`), and one that
  refuses a channel takes no more, its lease moving to a further connection; a lost connection is
  forgotten at once, so the next lease opens anew; `closeAll()` ends them all and cancels anyone
  waiting.
- **A session on a shared connection:** `ChannelTransport` leases a connection and runs the
  command as a channel, ending the lease when the stream ends. Bytes written before the first
  byte arrives are kept: a channel refused before then (`ConnectFailure.channelRefused`) moves
  the lease to a further connection once and is replayed there, unseen by the reader. A channel
  with no first byte in 15 s, while no other channel on the connection was heard from, means a
  dead link: the connection is invalidated and the stream ends as `sharedConnectionLost`.
  `ByteConnection.abandon()` (a session found its link dead) closes the channel and invalidates
  the connection too, unless another channel on it was heard from after this one's last byte.
  `SSHErrorClassifier.classifyChannel` reads a channel's stderr: refused by the master, or the
  master gone (ssh then tries a direct connection, which `ProxyCommand=/usr/bin/false` stops);
  both may reconnect.
- **The ControlMaster:** `SSHMasterCommand` builds the system ssh's arguments for one shared
  connection: the master (`SSHCommand`'s options first, then `-o ControlMaster=yes -o
  ControlPersist=no -S socket -N`), `-O check` and `-O exit`, and a channel through it
  (`ControlMaster=no`, and `ProxyCommand=/usr/bin/false` so a channel never signs in on its own).
  `ControlSocketDirectory` (macOS) is where the sockets live: the caches directory's `ssh/`, else
  `/tmp/glifftop-<uid>` when that path is too long for a socket or is refused; each is created
  0700, and refused if it is a symbolic link, not a directory or another user's. Sockets are named
  `<pid>-<n>`; before the app's first master, those of Glifftops no longer running (or with this app's own pid) are
  removed, sockets only, each master first ended with `-O exit`.
  `SystemSSHConnection` (macOS) is a `HostConnection` on such a master: `open` waits until the
  socket answers `-O check`, up to 60 s (then `ConnectFailure.signInTimedOut`, not retried);
  each channel is one ssh through the socket; the master's own exit, even a clean one, is a lost
  connection, and `close()` ends it with `-O exit`. `SystemSSH.opener()` is the app's opener for
  `HostConnections`; every opener shares one socket directory and one numbering.
- **Screens:** `ScreenChoice` is what a session shows (the focused monitor, one by name,
  or a virtual screen) as gliff-server's arguments. `ScreenListParser` reads the host's
  `hyprctl -j monitors` as untrusted input into `RemoteScreen`s: at most 1 MiB, names only
  `[A-Za-z0-9._:-]` (1–64), a description from make and model only (never the serial
  number), rotated monitors' sides swapped, disabled ones and gliff-server's own virtual
  screens (`gliff-<pid>`, gone when their session ends) left out. `ScreenListCommand` is
  the one-shot ssh for Get Screens: `SSHCommand`'s options, then a fixed one-line `sh -c`
  script that tries each Hyprland instance as gliff-server does (the session's own, then the
  newest whose socket answers) and prints `hyprctl -j monitors`. `ScreenLister` (macOS) runs
  it, as a channel on a `HostConnections` connection (`ScreenListCommand.remoteCommand`, the
  app's way) or as one ssh: output up to 1 MiB, a 60 s limit (room for a 1Password approval),
  failures in `SSHErrorClassifier`'s words; too much, too late or cancelled, it ends the
  process at once (`ProcessConnection.terminate`) or closes the channel, and it answers only
  once that is done. It and the `ssh -G` probe read output through `ProcessOutput`.
  `SSHCommand.remoteCommand` is the session's command line for a channel, as ssh sends it.
- **Processes (macOS only):** `ProcessTransport` runs a program and speaks over its
  stdin/stdout through `DispatchIO` (never blocking the cooperative pool); it keeps stderr's
  last 16 KiB for the classifier. `SystemSSHTransport` is that with `/usr/bin/ssh` and
  `SSHCommand.arguments`, after the `ssh -G` probe; cancelled by then, it throws
  `.cancelled` without starting ssh, as `ProcessOutput` does. `close()` closes stdin, waits 2 s, SIGTERMs, waits 1 s, SIGKILLs,
  and returns once the process is reaped; it also runs when the reader of `incoming` goes
  away.
