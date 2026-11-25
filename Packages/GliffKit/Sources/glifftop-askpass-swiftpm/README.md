# glifftop-askpass-swiftpm

The askpass helper as SwiftPM builds it, for the tests and the live check: one `main` calling
`AskpassHelper.run()`. The app embeds its own build of the same call, `glifftop-askpass`, from
its Xcode target; the names differ so Xcode never confuses the two.

It owns nothing else, and imports only Foundation and `GliffAskpass`.
