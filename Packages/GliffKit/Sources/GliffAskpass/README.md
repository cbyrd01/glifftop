# GliffAskpass

The askpass helper's logic and the wire between it and the app. ssh runs the helper
(`SSH_ASKPASS`) for each sign-in question; the helper hands ssh's prompt to the app's bridge
(`GliffTransport`'s `AskpassBridge`) over a Unix socket and gives ssh the answer.

- `AskpassWire`, `AskpassRequest`, `AskpassReply`: the frames, with a limit on every length
  (a prompt at most 8 KiB, an answer at most 1 KiB) and a version byte.
- `AskpassSocket`: the socket calls the helper and the bridge share.
- `AskpassHelper.run()`: the whole helper. The app's `glifftop-askpass` tool and SwiftPM's
  `glifftop-askpass-swiftpm` executable (for the tests and the live check) are each one line calling it.

Answers may be secrets: they are never built as an array or a string here, only read into a
buffer that is cleared after it is written to ssh. The helper never logs.

It imports only Foundation, and never another GliffKit module.
