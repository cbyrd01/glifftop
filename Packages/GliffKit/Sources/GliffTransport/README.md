# GliffTransport

Owns the byte stream to a gliff-server: the `Transport` seam, and ssh.

- **Imports:** Foundation, GliffProtocol (`OutputName`) and GliffAskpass (the helper's
  wire), plus the platform layers under it: `os` (Logger), `Synchronization` (Mutex, Swift's
  standard library); signals come through Foundation. Must not import GliffSession,
  GliffVideo, AppKit or UIKit.
- **Seam:** `Transport.connect()` gives a `ByteConnection` (`incoming` chunks, `write`,
  `close`). The session only sees this, so tests run against `tools/fake-server` instead
  of ssh.
- **ssh:** `SSHTarget` checks what was typed (trimmed; no leading dash, whitespace,
  control characters, ssh_config wildcards or the shell characters ssh refuses),
  `SSHCommand` builds the argv (`BatchMode=yes`,
  `StrictHostKeyChecking=yes` first so nothing can relax it, `IPQoS=ef`, keepalives that
  end a dead link after about a minute, a 10 s `ConnectTimeout` for a host that drops
  packets, added only when `ssh -G` (`SSHResolvedConfig`, read once per open, never logged)
  shows the person's ssh_config sets no timeout and no proxy (`SSHConnectTimeout`), `--` before the target, server arguments
  shell-quoted for the remote login shell), and `SSHErrorClassifier` turns ssh's stderr
  into a `ConnectFailure` with a plain-language `message` (for a changed host key, with the
  key ssh printed; the `ssh-keygen -R` name of the old key comes from the person's ssh config,
  never from that text, which a host can write).
- **Sign-in questions:** `SignInQuestion` (an unknown host key, a passphrase or PIN, a
  password, the host's own question, a notice) and `SignInAnswer` are the same whichever ssh
  asks them; a `SignInAsker` (the app's window) answers. A `SignInSecret` holds a typed secret
  in memory of its own, cleared when it goes, and lends its bytes only to `withBytes`.
  `AskpassPrompt` tells ssh's questions apart by its own templates, anchored at the prompt's
  first byte; a prompt starting "(" is the host's text after ssh's "(USER@HOST) ", never
  matched against a template, and an unknown prompt is nil. A name ssh writes for the
  destination (its HostName or HostKeyAlias, from `ssh -G`) is shown as the host typed; any
  other is a jump host's. `SignInQueue` (main actor) is a window's asker: its questions shown
  one at a time as `current`, each ask that is cancelled answered `.cancel` and taken away.
  `SignInQuestion.shownHostText` is the host's own text as a sheet may show it (line breaks
  kept, no other control or format characters, at most 8 KiB), `keyPath` the key file a
  passphrase question names, `user` a password's user (from ssh's USER@HOST), and
  `hostShown` the host as typed, for a heading (never ssh's resolved HostName).
- **A master that may ask:** `MasterAsking`, from the resolved config (nil under `BatchMode
  yes`), drops `BatchMode=yes` from the master only, gives ssh `-n`, keeps
  `StrictHostKeyChecking=yes` when the config says so and asks otherwise (never `accept-new`
  or `no`), and turns a config's `UpdateHostKeys ask` and `AddKeysToAgent ask` off. `check`, `exit` and channels keep
  their guards.
- **The askpass bridge:** `AskpassBridge` listens on a 0600 socket beside the master's
  (`<pid>-<n>-a` in `ControlSocketDirectory`), for the helper ssh runs. It serves a
  connection only from this user's helper whose parent is the master's ssh or a jump host's
  under it (`AskpassPeer`: uid, the audit token's executable, the parent chain), with the
  one-time token, one question at a time, at most 10. Allow on a host key answers its
  fingerprint; a secret is written from its own memory. Cancel or any refusal ends the master
  before the helper is refused, so ssh never sends an empty answer: ending a process ends its
  process group (`ProcessConnection.endGroup`), stopped while it is signalled, so no ssh in it
  that waits on a helper runs on after the helper's end. Every connection it doesn't answer is refused (`.refuse`),
  as a helper whose socket closes with no reply ends its ssh;
  `revoke()` ends the token, and `revoke(ready: true)`, once the master is ready, refuses what
  is left without ending it. A question it can't recognise fails as `unknownQuestion`. It
  logs a question's number and kind only: never its text, an answer, a destination, a
  socket or a key path.
- **Shared connections:** `HostConnection` is one signed-in connection to a host that runs
  shell commands as channels (`ByteConnection`s); a system ssh ControlMaster or an embedded ssh
  can each be one. `HostConnections` (an actor) keeps one per destination as typed, held by
  `HostLease`s: everyone asking while one opens waits for that one sign-in; it closes 10 s after
  its last lease ends; a sign-in that asked and failed (the agent or the key refused, no
  approval in a minute, the person's Cancel, a denied key, too many questions) answers that
  destination for 10 s unless a connection there has room, and a `fresh` lease (an attempt the
  person starts) asks again; an open started by a lease with an asker (a window) asks its
  sign-in questions through `SignInRouter`: each goes to the oldest waiting lease with an
  asker, a question about a host key (`.hostKey`, `.confirm`) only to a `fresh` one (with
  none, it is denied and the open fails as `hostKeyUnchecked`), and a waiter that leaves hands
  its question to the next; with none, it waits 1 s for one, then cancels it, a cancel not
  remembered; an open nobody has waited for
  in 1 s is cancelled (so a session that starts as a listing stops shares its sign-in); a connection takes at most 10 leases (sshd's `MaxSessions`), and one that
  refuses a channel takes no more than its sessions (a spare's channel among them, which yields), its lease moving on; a lost connection is
  forgotten at once, so the next lease opens anew; `closeAll()` ends them all and cancels anyone
  waiting.
- **Following a host's connections:** `events(for:)` streams a host's `ConnectionEvent`s
  (opened, ended with why once closed, a place freed). `attach(to:)` gives a `PassiveLease` on the busiest
  live connection, nil when none: it never opens, moves or asks, and doesn't keep the
  connection, whose grace starts when only passive leases remain. It forwards and cancels on
  its connection, and holds no place but at most one spare (`takeSpare`), for a channel of its
  own (`spareChannelEnded()` says when that channel is gone); a lease that finds the connection
  full calls the spare's `yield` and takes that place without an open. A spare the host refuses lowers the connection's limit to the places in use.
- **Port forwards on a connection:** `HostConnection.forward(_:on:)` listens on one of this
  Mac's loopbacks (`Loopback`: 127.0.0.1 or ::1) and carries each connection to the host;
  `cancel(_:on:)` ends it; `configuredForwards` are the person's ssh_config forwards. A
  `PortForward` has a local port of 1024–65535, a remote port and a `ForwardDestination`
  (`localhost`, a parsed `IPLiteral` without a zone, or a config's host name with no NUL,
  whitespace, `/`, brackets, `:` or `%`; a config's IP literal is an `IPLiteral`), and no bind
  address. Failures are `ForwardError`s, which name no ssh text.
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
  ControlPersist=no -o ForkAfterAuthentication=no -S socket -N`), `-O check` and `-O exit`, a channel
  through it (`ControlMaster=no`, and `ProxyCommand=/usr/bin/false` so a channel never signs in
  on its own; `SSHCommand.channelOptions` turn off agent and X11 forwarding, local and remote
  commands, a terminal and a subsystem, keep stdin and stay in the foreground, whatever the
  config says), and `-O forward` and `-O cancel`.
  `ControlSocketDirectory` (macOS) is where the sockets live: the caches directory's `ssh/`, else
  `/tmp/glifftop-<uid>` when that path is too long for a socket or is refused; each is created
  0700, and refused if it is a symbolic link, not a directory or another user's. Sockets are named
  `<pid>-<n>`; before the app's first master, those of Glifftops no longer running (or with this app's own pid) are
  removed, sockets only, each master first ended with `-O exit`.
  `SystemSSHConnection` (macOS) is a `HostConnection` on such a master: `open` reads the
  config once (`ssh -G`) and waits until the socket answers `-O check`, up to 60 s not counting
  time a sign-in question is open, and 5 min in all (then `ConnectFailure.signInTimedOut`, not
  retried). With a `SignInAsker`, the askpass helper and a config that allows it, the master asks
  (`SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE=force`, its stderr unlogged) through a bridge revoked once
  the master is ready or has failed; the bridge's outcome names the failure (`hostKeyDenied`,
  `signInCancelled`, `tooManyQuestions`, `unknownQuestion`), and a changed key's known_hosts
  name is the config's, none when it keeps its own known_hosts file.
  Without them, or when the probe fails, the master runs in batch mode. Each channel is one ssh
  through the socket; the master's own exit, even a clean one, is a lost connection, and
  `close()` ends it with `-O exit`. `SystemSSH.opener(helper:)` is the app's opener for
  `HostConnections`, asking through the asker `HostConnections` gives it; every opener shares one socket directory and one numbering.
- **The config's port forwards:** every ssh this module starts runs with
  `ClearAllForwardings=yes` (`SSHCommand`'s options, a channel's), and control requests read no
  config (`-F none`), so ssh opens none of the config's forwards: one on a busy port would end
  the master under `ExitOnForwardFailure yes`, or fail a channel, which asks the master for
  them. `SSHResolvedConfig` reads the `LocalForward` lines (`SSHLocalForward`, its bind address kept for display), and `configuredForwards`
  gives them for GliffPorts to apply. `RemoteForward`, `DynamicForward`, and unix-socket,
  under-1024 or otherwise unholdable `LocalForward` lines don't apply; `notAppliedLines` keeps
  their text, and `NotAppliedReason` says which are a Mac port under 1024. Only counts are
  logged.
- **Forward and cancel on the master** (`SystemSSHConnection+Forwards`): `-O forward` or
  `-O cancel` with an `SSHForwardSpec` (`127.0.0.1:P:dest:port` or `[::1]:P:dest:port`, from
  typed values only), one request at a time per connection (`MasterRequests`), each within
  5 s. `SSHForwardClassifier` reads ssh's status and stderr, which are never logged: a busy
  port is `.localPortInUse`, the master gone or ending `.connectionLost` (only then, whatever
  ssh said), and cancelling a forward
  already gone succeeds. Asking for a forward the master already holds succeeds too.
  `LoopbackPorts` checks a port by binding 127.0.0.1 and ::1 without `SO_REUSEADDR`, so a Mac
  server on `*:P`, which ssh's bind would shadow, makes the port taken.
- **Screens:** `ScreenChoice` is what a session shows (the focused monitor, one by name,
  or a virtual screen) as gliff-server's arguments. `ScreenListParser` reads the host's
  `hyprctl -j monitors` as untrusted input into `RemoteScreen`s: at most 1 MiB, names only
  `[A-Za-z0-9._:-]` (1–64), a description from make and model only (never the serial
  number), each monitor's top-left in the host's layout (`x`, `y`: nil unless a whole
  number within ±1,048,576), rotated monitors' sides swapped, disabled ones and
  gliff-server's own virtual screens (`gliff-<pid>`, gone when their session ends) left out
  (`isMonitorName`). `ScreenListCommand` is
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
  away. After the process exits, a pipe a grandchild still holds is closed at a check each
  second unless bytes or its end wait in it with nothing read since the last check
  (`ExitGrace`, at most 10 checks): a reader running late loses none of the process's
  output, and a grandchild still writing doesn't hold the end back.
