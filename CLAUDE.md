# CLAUDE.md

Guidance for Claude Code (claude.ai/code) in this repository. Machine-specific notes (a test
host, ssh aliases, local paths, work in progress) go in `CLAUDE.local.md`, which is git-ignored
and loaded automatically.

# Glifftop

An unofficial native Mac client for [Gliff](https://github.com/omacom/gliff), the remote
desktop for Hyprland/Omarchy, written in Swift. Not affiliated with Gliff.

## Status

- **Works:**
  - connecting over ssh;
  - the picture (H.264 through VideoToolbox, Dual420 recombined in Metal);
  - keyboard and pointer capture, and the remote cursor shape;
  - choosing the screen (a monitor, the focused one, or a virtual screen that follows the window);
  - the shared clipboard: text, HTML and images, both ways, off until turned on;
  - saved machines with their options, and reconnecting by itself after a lost link;
  - tabs and windows, one session each, sharing one ssh connection per host, with input and
    the host's focus following the window on top.
- **Not yet:**
  - files over the clipboard;
  - an optional event tap for ⌘Space and ⌘Tab (they stay with the Mac);
  - signed releases.
- **Known, upstream:** Hyprland 0.56.2 shares every cursor image fully transparent, so over a
  monitor the Mac arrow shows; a virtual screen's picture carries the host's own pointer, as
  does a `HEADLESS-N` monitor's (Hyprland's headless backend, such as a container's).

## Engineering rules

- **Latest OS and tools only.**
  - The deployment target is macOS 27; GliffKit also declares iOS 27
    (`swift-tools-version: 6.4`).
  - Use the newest Apple APIs freely, with no `#available` guards and no fallbacks for older
    systems.
  - The targets rise with each new major OS.
- Never put Liquid Glass on the video view; use it only on chrome and overlays.
- **A general-purpose client:** Glifftop connects to any compatible Gliff server. Never
  hardcode a host in code, UI text, defaults or designs; UI text names the host the person
  typed. Examples use `omarchy`.
- Swift 6 language mode, strict concurrency, no warnings.
- SwiftUI app lifecycle with Observation; AppKit only where SwiftUI can't do the job (the
  video and input view, the pasteboard, the cursor).
- Small modules in the local package `Packages/GliffKit`, with dependencies pointing one way.
  - Everything below the UI imports only Foundation, VideoToolbox, CoreMedia, Metal,
    CoreVideo, `os` and `Synchronization`.
  - GliffKit compiles for iOS (`scripts/ios-check.sh`).
- **No third-party Swift packages.** Rust is allowed only in `tools/`, as test tooling.
- Swift Testing (`import Testing`), with TDD: watch each test fail before writing the code
  that passes it.
- Log through `os.Logger` with subsystem `me.cbyrd.Glifftop`. No `print`.
- **Never log clipboard contents, remote mime types, file names or paths.** Log counts only.
- Small, single-purpose files of at most 400 lines. Each module has a `README.md` saying what
  it owns and what it must not import.
- Comments and docs state the current rule or fact. History belongs in git.
- `scripts/test.sh` is the gate before every commit.

## Workflow

- Each piece of work is built on its own branch and lands on `main` through a pull request.
  `main` is protected: pull requests only, no force push or deletion.
- Per task: the gate, then `/simplify`, then the gate, then `/code-review high` (fix each
  finding test-first), then the gate, then commit.
- The git `pre-commit` hook blocks Claude's commits that change code, or the files through
  which third-party code enters, unless `/simplify` and `/code-review` both ran since the last
  commit.
- A milestone ends with `/code-review xhigh`, `/security-review` and
  `scripts/check-upstream.sh`.

## Apple skills

Apple's Xcode agent skills (`swiftui-specialist`, `swiftui-whats-new-27`, `modernize-tests`,
`xctrace`) are used from `.claude/skills/`. Apple's licence doesn't allow redistributing them,
so they are not in the repo: `scripts/check-apple-skills.sh --install` exports them from your
own Xcode, if they match the reviewed checksums in `scripts/apple-skills.sha256`. After an
Xcode update, run `scripts/check-apple-skills.sh`; it keeps a changed export in
`.build/apple-skills-export` for review.

This file wins over any skill, including a skill's "supersedes prior training" claims:

- `swiftui-specialist`: its examples use `print`; we use `os.Logger`. GliffKit never imports
  SwiftUI.
- `swiftui-whats-new-27`: never add `#available` gating. Check each API's macOS column: toolbar
  overflow, pinned trailing and status-bar placements are iOS-only.
- `modernize-tests`: Swift Testing only, no XCTest, not even for UI or `measure` tests.
- `audit-xcode-security-settings` is not adopted; any setting from it goes into
  `Config/*.xcconfig`, never the project file.

## Setup

- Building the app needs only Xcode 27.2 and its Metal Toolchain (`xcodebuild
  -downloadComponent MetalToolchain`, or Xcode ▸ Settings ▸ Components).
- **The gate needs more, once per clone:** `mise install` (gitleaks, Rust 1.100, sfw; pinned
  in `mise.toml`, checksums in `mise.lock`), then `scripts/cargo-net.sh fetch --locked`.
- **Committing and Claude Code need, once per clone:** `scripts/install-hooks.sh` (sets
  `core.hooksPath` to `scripts/git-hooks`) and `scripts/check-apple-skills.sh --install`.
- **Crate downloads go through Socket Firewall Free (`sfw`), never plain cargo.**
  - `.cargo/config.toml` sets `net.offline = true`. A "--offline was specified" error means
    run `scripts/cargo-net.sh fetch --locked`.
  - `scripts/cargo-net.sh <cargo args>` is the only online path. Don't pass
    `net.offline=false` or `CARGO_NET_OFFLINE` any other way.
  - Cargo's `min-publish-age` cooldown is 7 days. Cargo dependencies always use `--locked`.
  - sfw only sees downloads: a crate already in `~/.cargo/registry`, or a git dependency, isn't
    checked.
  - sfw is third-party (PolyForm Shield licence), and its telemetry can't be turned off:
    machine id, package names and versions, and the GitHub org from git remotes.

## Commands

- **Full gate:** `scripts/test.sh`. It prints one line per step, and on failure only that
  step's output. It runs, in order:
  - gitleaks;
  - `swift format lint --strict` (GliffKit, the app and `tools/encode-fixtures`);
  - `scripts/check-sources.sh` (no `print`/`debugPrint`/`dump`/`NSLog` outside tests, files of
    at most 400 lines, a `// reason` line above each `swift-format-ignore`);
  - `scripts/check-xcodeproj.sh` (no setting both in the project and in `Config/`);
  - the scripts' own tests, `scripts/tests/*-test.sh` (stub tools, no network);
  - `cargo build` and `cargo test` of `tools/fake-server` (`--locked`);
  - the fixture drift check: the golden fixtures and synthetic planes, regenerated from the
    pinned upstream Rust, must match the committed bytes;
  - `swift test` of `tools/encode-fixtures` (it never runs the tool);
  - `swift test`, with `GLIFFTOP_FAKE_SERVER` pointing at the built fake server, ended after
    10 minutes (`scripts/time-limit.sh`), naming the tests that never finished;
  - `scripts/app-build.sh`, an `xcodebuild` of the app into `.build/xcode`;
  - `scripts/ios-check.sh`.
- **GliffKit tests:** `cd Packages/GliffKit && swift test`. For one suite, add
  `--filter CBORTests` (or another suite name).
- **Secret scanning:** gitleaks is pinned in `mise.toml`, and the pre-commit hook runs
  `gitleaks git --pre-commit --staged`.
  - Record a false positive in `.gitleaksignore`, by fingerprint.
  - Don't loosen `.gitleaks.toml`, and don't use `--no-verify`.
- **Claude Code hooks** (`.claude/hooks/`, wired up in `.claude/settings.json`) act on the
  session's working directory, so they follow a git worktree.
  - `format-lint.sh` runs after every Edit/Write of a `.swift` file: `swift format` in place,
    then `swift format lint --strict` and `scripts/check-sources.sh`. Exit 2 means fix the
    reported violations.
  - `stop-gate.sh` runs when Claude stops:
    - if GliffKit's Swift changed since `HEAD`, GliffKit must build, tests included;
    - if `Glifftop/` or `Config/` changed, the app must build.
    - It skips the build when the tree is unchanged since its last clean pass.
  - `record-review.sh` notes each `/simplify` and `/code-review`, with the `HEAD` it ran at, in
    `.git/claude-reviews`, for the pre-commit hook.
  - **Guardrails:** `.claude/settings.json` denies edits to:
    - `.swift-format`, `.gitleaks.toml`, `.claude/settings.json`, `.claude/hooks/`,
      `scripts/git-hooks/`;
    - `Glifftop.xcodeproj/`, `.cargo/`, `scripts/cargo-net.sh` and the capture checks;
    - `--no-verify`, `CLAUDECODE`, `core.hooksPath`, and cargo-offline and crate-cooldown
      overrides.

    These are guardrails against slips, not a security boundary. Only the maintainer changes
    those files.
- **The app project:** `Glifftop.xcodeproj` is a plain Xcode project, and it is committed.
  - App sources live in `Glifftop/`, a synchronized folder: add files there with no project
    edit.
  - Build settings live in `Config/*.xcconfig`.
  - The project file is `Glifftop.xcodeproj/project.xcproj`, Xcode 27's JSON5 text format.
    Read it freely (`plutil -convert json -o - …`), but never edit it; structural changes are
    made in Xcode by the maintainer.
- **Golden fixtures** come from upstream's Rust and are committed.
  - Regenerate them with
    `cargo run --quiet --locked --manifest-path tools/fake-server/Cargo.toml -- fixtures Packages/GliffKit/Tests/GliffProtocolTests/Fixtures`.
  - Never hand-edit `.cbor` fixtures, plane files or `.h264` streams. A drift failure means the
    Swift side, or the pinned rev, is wrong.
  - `glifftop-fake-server planes <dir>` writes the synthetic video pictures (Dual420 planes and
    the BGRA a client must show) with upstream's own colour and chroma code.
  - `tools/encode-fixtures` (Swift, Apple frameworks only) encodes the planes into the H.264
    test streams in `…/Fixtures/synthetic/streams`. VideoToolbox's bytes can change between
    OS releases, so the gate doesn't run it: regenerate by hand (its README) and review the
    diff.
- **The fake server:** `glifftop-fake-server serve <scenario> [flags]` is a scripted
  gliff-server on stdin/stdout (`serve` with no scenario prints the list). It exits 0 when the
  client behaved, 1 with one `fake-server: ` line on stderr when it didn't, and 2 on bad usage.
  - `serve stream --streams DIR [--size WxH]` replays `NNN.main.h264` (and `NNN.aux.h264`
    under Dual420) from `DIR`, one file per frame, the first a keyframe.
  - `serve input [--keymap-first] [--expect-keys N] [--expect-pointer N] [--expect-nudge]`
    streams two frames, then checks the client's input until Bye or EOF:
    - no key or button pressed twice, released unheld, or still held at the end;
    - motion inside the streamed 1280×720 output;
    - a scroll's value finite, and its stop after a scroll of that axis;
    - no empty keymap.

    The flags require the Keymap first, at least N keys, and at least N pointer messages;
    `--expect-nudge` requires a window activation's nudge before any other input: two motions
    1 apart on x, at the same y.
  - `serve cursor [--valid-only]` sends three cursor shapes after the StreamConfig, then two
    frames:
    - a valid 2×2 shape (id 7), its frame four bytes longer than it declares;
    - one with its hotspot outside (id 8);
    - one whose pixels are a byte short (id 9).

    `--valid-only` sends only the first.
  - `serve resize [--headless] [--expect-resizes N]` streams two frames.
    - It then answers each Resize much as upstream does, with a StreamConfig and a keyframe: a
      mirror of its 1280×720 output fitted, never larger; a virtual screen rounded by
      `clean_mode`.
    - It fails on a Resize under 320×240, a scale outside 0.5–4, the same request twice, or
      fewer than N.
  - `serve clipboard-offer [--hostile]` streams two frames, offers text, HTML and a PNG, and
    serves each request until Bye or EOF.
    - It fails on an even or reused id, another serial, a file request, client `Data`, an abort
      of an id never requested, or a client offer with files.
    - `--hostile` sends a stray chunk first and each HTML as one chunk over 256 KiB, and fails
      unless the client aborts each.
  - `serve clipboard-request` streams two frames, then needs the client's text offer and reads
    it at once.
    - The text must come in order, as the test pattern (byte i is i % 251), over more than four
      chunks and never past the window.
    - With four chunks unacked it asks for a type not offered, which must be refused before a
      fifth chunk.
    - A stale serial and an odd id must be refused.
    - Then it offers its own clipboard and waits for Bye.
- **Live check** (needs a real host; a headless session): run
  `GLIFFTOP_LIVE_HOST=<ssh host> GLIFFTOP_LIVE_SECONDS=60 swift test --no-parallel --filter
  'LiveSessionTests|LiveResolutionTests|LiveScreenListTests|LiveClipboardTests|LiveHostConnectionTests|LiveFocusTests'
  --attachments-path DIR` in `Packages/GliffKit`.
  - It streams the screen, resizes a virtual screen (which the server removes at the end),
    asks for one at Standard (and at Automatic with `--video cpu`) and lists the monitors.
  - It opens the app's own ControlMaster: two channels on one master, and a channel without its
    master failing at once, with no second sign-in.
  - It offers two test strings as the Mac's clipboard, an ordinary one and one marked as a
    password. Each becomes the host's clipboard; the ordinary one stays in its clipboard
    history, and the password must not.
  - It opens two virtual screens on one master, with a terminal on each (closed by address at
    the end): activation moves the host's focus to the screen in front, the host's pointer
    matches `hyprctl cursorpos`, and Super held on one screen types no digit on the other.
  - It writes numbers-only `live-*.txt` files. It is off in the gate.
- **Captures:** screenshots, screen recordings and `.gliffrec` stream recordings stay local in
  `.recordings/` (git-ignored).
  - Committing one needs the maintainer's approval of that exact file:
    `scripts/approve-capture.sh <file>` is interactive, and Claude never runs it.
  - `scripts/check-captures.sh` (pre-commit) refuses any staged capture without a matching
    line in `captures.sha256`.
  - Synthetic fixtures and `Glifftop/Assets.xcassets/` are exempt.
- **Watching upstream:** `scripts/check-upstream.sh` (one read-only `gh release list`) says
  whether gliff has released a version newer than the pinned one. Adopting one is the
  maintainer's call; the steps are in README.md, "Updating upstream".

## Architecture

```
Glifftop.app   Glifftop/: AppShell (SwiftUI windows, settings) + MacPlatform (AppKit adapters)
GliffKit       Packages/GliffKit/, platform-neutral, one target per module
  GliffMachines   saved machines and their options, as JSON for the app to store; a new tab's
                  options and the tabs' titles
  GliffSession    per-window actor: handshake, reader/writer tasks, acks, resize, input order
  GliffClipboard  offer/request/data/ack/abort state machine, sharing policy (no pasteboard)
  GliffVideo      H.264 → VideoToolbox (2 sessions) → Metal recombine → BGRA texture
  GliffInput      macOS keycode → evdev, key ledger, XKB keymap text, pointer mapping, cursor,
                  focus target, the tab chord
  GliffTransport  `Transport` protocol; HostConnections: one ssh ControlMaster per host, each
                  session a channel on it (ChannelTransport) running gliff-server --stdio
  GliffProtocol   frame header, minimal CBOR, ClientMessage/ServerMessage; pure, no I/O
  GliffAskpass    the askpass helper's logic and its wire to the app; the app's helper tool
                  links only this
  GliffTestSupport  test doubles shared by the test targets (ManualClock); never in the product
```

- Dependencies point down only. `GliffProtocol` depends on nothing. `GliffSession` composes
  the others. AppShell never imports AppKit; MacPlatform adapts AppKit to the GliffKit
  interfaces and never uses AppShell's views.
- The `Transport` seam is how integration tests swap ssh for `tools/fake-server`.
- **Protocol rules with sharp edges:**
  - Send exactly one `FrameAck` per `VideoFrame`, even when decode fails, and send it after
    the GPU work, not after display.
  - Skip unknown messages and variants.
  - The client allocates odd clipboard transfer ids.
  - Use `BatchMode=yes`, and never `StrictHostKeyChecking=accept-new`.
- Upstream's Rust at the pinned release is the source of truth for wire behaviour: when in
  doubt, read `crates/gliff-proto/src/{msg,frame,clipboard}.rs` and
  `crates/gliff/src/net.rs`. The pinned source is in cargo's git checkout of gliff-proto.

## Safety

- **Upstream code** enters only through the pinned git rev in `tools/fake-server`
  (`Cargo.lock`). Clones kept for reference are read, never built or run.
- **A test host:** read-only checks are fine. Ask before installing, changing or deleting
  anything there. A live test may set the host's clipboard to a test string.
- **Pushing:** pushing a work branch and opening its PR is part of the workflow. Ask before
  any other push; never force-push.
- **Third-party code needs the maintainer's OK.** Before installing, adding or first building
  anything not authored by Apple or Anthropic, name it as third-party and ask. That includes
  brew or mise tools, skills, plugins, MCP servers, Rust crates and GitHub Actions. Crate
  build scripts run code on build. Prefer Apple- or Anthropic-only options.
- **Personal details:** never put the user's name, email or hosts in requests to outside
  services.

## Environment

- macOS 27 on Apple Silicon, Xcode 27.2 with the Metal Toolchain, Swift 6.4.
- Rust 1.100 from mise, the first release with Cargo's stable `min-publish-age` cooldown.
- mise's `minimum_release_age` holds back tool versions newer than 24 h.
