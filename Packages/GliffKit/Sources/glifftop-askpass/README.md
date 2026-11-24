# glifftop-askpass (SwiftPM)

The askpass helper as SwiftPM builds it, for the tests and the live check: one `main` calling
`AskpassHelper.run()`. The app embeds its own build of the same call, from its Xcode target.

It owns nothing else, and imports only Foundation and `GliffAskpass`.
