# GliffAskpass

The askpass helper's logic and the wire between it and the app. ssh runs the helper
(`SSH_ASKPASS`) for each sign-in question; the helper hands ssh's prompt to the app's bridge
(`GliffTransport`'s `AskpassBridge`) over a Unix socket and gives ssh the answer.

- `AskpassWire`, `AskpassRequest`, `AskpassReply`: the frames, with a limit on every length
  (a prompt at most 8 KiB, an answer at most 1 KiB) and a version byte.
- `AskpassSocket`: the socket calls the helper and the bridge share.
- `AskpassHelper.run()`: the whole helper. The app's `glifftop-askpass` tool and SwiftPM's
  `glifftop-askpass-swiftpm` executable (for the tests and the live check) are each one line
  calling it.

Answers may be secrets: they are never built as an array or a string here, only read into a
buffer that is cleared after it is written to ssh. The helper never logs.

ssh reads a failed helper as an empty answer, and sends an empty password to the host. The
bridge refuses (`.refuse`) every question it doesn't answer, and removes its socket when it
stops. So the helper takes a question whose socket closes with no reply, or whose socket is
still there but refuses the connection, as the app gone (a crash, Force Quit): it ends its
parent ssh (SIGTERM, only `/usr/bin/ssh`) before exiting 1. A notice never does.

It imports only Foundation, and never another GliffKit module.
