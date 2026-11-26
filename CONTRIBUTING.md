# Contributing

Thank you for your interest in Glifftop.

- **Issues are welcome:** bugs, ideas and questions. Please use the issue forms.
- **Pull requests aren't open yet.** For now, open an issue instead and describe the change.
- **Security problems** go through private reporting; see [SECURITY.md](SECURITY.md).

## Building and testing

Building the app needs only Xcode 27.2 and its Metal Toolchain (see the README). The full
checks need more, once per clone:

```sh
mise install                              # gitleaks, Rust 1.100 and sfw, pinned in mise.toml
scripts/install-hooks.sh                  # the git hooks in scripts/git-hooks
scripts/cargo-net.sh fetch --locked       # the test tooling's Rust crates, through sfw
scripts/check-apple-skills.sh --install   # Apple's Xcode agent skills, for Claude Code
```

Then `scripts/test.sh` runs every check: the secret scan, `swift format lint`, the source and
project checks, the scripts' tests, the fake server's build and tests, the fixture drift
check, GliffKit's tests, the app build and an iOS compile check of GliffKit.
`cd Packages/GliffKit && swift test` runs GliffKit's tests alone.

## The app icon

`Glifftop/AppIcon.icon` is an Icon Composer document (the target's App Icon, `AppIcon`), from
which Xcode builds every platform's icon and appearance. It is a lowercase g whose bowl frames a
tiled desktop:

- the background, a gradient set in `icon.json`, not an image;
- two groups of flat SVG layers on the full 1024 × 1024 canvas, numbered back to front: the g
  (`1-g.svg`), then the three tiles. Each layer is one shape in one colour, with its Dark colour
  in `icon.json`.

The SVGs carry no mask, shadow, gloss or blur: the system adds the shape and Liquid Glass, with
each group's shadow and translucency set in `icon.json`. Clear and Tinted are generated. Edit
the icon in Icon Composer (`open Glifftop/AppIcon.icon`), or preview it from the command line
with its `ictool` (into `.build/`, which git ignores):

```
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  Glifftop/AppIcon.icon --export-image --output-file .build/icon.png --platform macOS \
  --rendition Default --width 512 --height 512 --scale 1
```

## Things to know

- **Third-party tools.** [mise](https://mise.jdx.dev) installs the pinned tools.
  [Socket Firewall Free](https://socket.dev) (`sfw`) screens every crate download for known
  malware: cargo is offline otherwise, and `scripts/cargo-net.sh` is the only online path.
  sfw is third-party (PolyForm Shield licence), and its telemetry can't be turned off: it
  sends a machine id, package names and versions, and the GitHub organisation from your git
  remotes.
- **Rules.** CLAUDE.md holds the project's engineering rules, for people and for Claude
  Code alike: Swift 6 with strict concurrency, Swift Testing with tests first, `os.Logger`
  only, files of at most 400 lines, the newest macOS only.
- **Claude Code.** The project is built with [Claude Code](https://claude.com/claude-code).
  Its hooks in `.claude/` format and lint Swift after each edit, build before Claude stops,
  and keep Claude's commits behind a code review. They do nothing outside Claude Code.
- **Captures.** Screenshots and recordings stay in `.recordings/` (git-ignored). The
  pre-commit hook refuses one in a commit unless the maintainer has approved that file.
