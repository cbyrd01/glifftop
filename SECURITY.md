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
- **The remote computer** is trusted with what you send it: your keystrokes while captured,
  and your clipboard while sharing is on. Everything it sends back (video, cursor images,
  clipboard data, the monitor list) is read as untrusted and checked for size and shape.
- **The clipboard** is shared only after you turn it on and confirm. While Glifftop is in
  front, what you copy on the Mac, passwords included, goes to the remote computer; an item
  marked as a password is flagged so the remote's clipboard history can leave it out. A copy
  made on the remote before you connected is never brought to the Mac.
- **Logs** go to the system log (subsystem `me.cbyrd.Glifftop`). They never contain clipboard
  contents, clipboard types, file names or paths.

## How the app is built

- Not sandboxed: the App Sandbox doesn't allow running `/usr/bin/ssh` with your own ssh
  config and agent. The hardened runtime is on in release builds.
- No third-party Swift packages. Rust appears only in `tools/`, as test tooling, and never
  ships in the app.
- Releases aren't published yet. They will be signed with a Developer ID and notarized by
  Apple; until then, build from source.
