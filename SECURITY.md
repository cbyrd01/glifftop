# Security

## Reporting a vulnerability

Please report it privately, through GitHub's
[private vulnerability reporting](https://github.com/cbyrd01/glifftop/security/advisories/new)
(the repository's **Security** tab ▸ **Report a vulnerability**). Don't open a public issue.

Glifftop is maintained by one person in their own time: expect an answer within a week. Only
the latest commit on `main` is supported.

## What Glifftop trusts

- **ssh.** Glifftop runs the system's `/usr/bin/ssh`, with its own options ahead of anything
  in your ssh config. Opening a connection to a host asks ssh's questions in the window
  through Glifftop's askpass helper: an unknown host key (Allow adds it to `known_hosts`), a
  password, a passphrase or the host's own question. `StrictHostKeyChecking` is `yes` or
  `ask`, never `accept-new` or `no`, so a changed host key is always refused. The helper
  answers only ssh processes Glifftop started, over a socket only you can open, with a
  one-time token. Everything else runs with `BatchMode=yes`. It uses your ssh config, keys
  and agent; it stores no credentials, and never logs or writes what you type.
- **Port forwards** listen on this Mac's 127.0.0.1, and ::1 when it has one, nowhere else, on
  ports of 1024 or more. Of your config's forwards only `LocalForward` lines apply, each bound
  to loopback whatever address it names; `RemoteForward` and `DynamicForward` lines don't.
  Before every forward, the config's included, Glifftop checks that no Mac server already
  listens on that port, so a forward never shadows one. Loopback isn't private: any process
  on this Mac, and a web page in its browser, can reach a forwarded port. So a new port on the
  host is offered, not forwarded, unless you turn on **Forward new ports automatically**; even
  then, nothing is forwarded unasked when the host can't name its listeners, and database and
  cache ports are only offered. Every forward shows in the Ports popover, and they end with the
  host's windows. To list its ports, Glifftop runs a fixed shell script on the host that reads
  `/proc/net/tcp` and `ss`; its output is read as untrusted.
- **The remote computer** is trusted with what you send it: your keystrokes while captured,
  and your clipboard while sharing is on. Everything it sends back (video, cursor images,
  clipboard data, the monitor list) is read as untrusted and checked for size and shape.
- **The clipboard** is shared only after you turn it on and confirm. While Glifftop is in
  front, what you copy on the Mac, passwords included, goes to the remote computer; an item
  marked as a password is flagged so the remote's clipboard history can leave it out. A copy
  made on the remote before you connected is never brought to the Mac.
- **Logs** go to the system log (subsystem `me.cbyrd.Glifftop`). They never contain clipboard
  contents, clipboard types, file names or paths, nor port numbers, addresses, destinations
  or process names.

## How the app is built

- Not sandboxed: the App Sandbox doesn't allow running `/usr/bin/ssh` with your own ssh
  config and agent. The hardened runtime is on in release builds.
- No third-party Swift packages. Rust appears only in `tools/`, as test tooling, and never
  ships in the app.
- Releases aren't published yet. They will be signed with a Developer ID and notarized by
  Apple; until then, build from source.
