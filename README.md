# Glifftop

**An unofficial native Mac client for [Gliff](https://github.com/omacom/gliff)**, the
remote desktop for Hyprland and Omarchy. Not affiliated with the Gliff project.

Glifftop connects over ssh to a machine running the stock `gliff-server` and shows its
desktop in a native macOS window.

![Glifftop showing an Omarchy virtual screen: omarchy.org, LazyVim and btop side by side](docs/media/virtual-screen.png)

The name combines *gliff*, the Scots word for a glimpse, with *desktop* and *clifftop*.

## Status: preview

**Works:**

- Connecting over ssh, with your own ssh config, keys and agent. ssh's questions come up in
  the window: a new host's key to allow or deny, a password, or a key's passphrase.
- Sharp 4:4:4 colour: H.264 decoded with VideoToolbox and recombined on the GPU.
- Keyboard and pointer capture with your own keyboard layout, and the remote cursor shape.
- Choosing the screen: one of the host's monitors, the focused one, or a virtual screen that
  follows the window's size.
- A shared clipboard (text, HTML and images, both ways), off until you turn it on.
- Saved machines, each with its options, and reconnecting by itself after a lost link.

<img src="docs/media/screensaver.png" width="480" alt="Omarchy's screensaver in Glifftop: the logo's colour gradient, sharp at full chroma">

**Not yet:**

- Files over the clipboard.
- ⌘Space and ⌘Tab stay with the Mac.
- Signed releases: for now, build it yourself.

**Known, upstream:** Hyprland 0.56.2 shares every cursor image fully transparent, so over a
monitor the Mac arrow shows. A virtual screen draws the host's own pointer into the picture,
as does a monitor of Hyprland's headless backend (`HEADLESS-N`, such as a container's), so
there the Mac pointer is hidden and the host's shows, a frame behind.

## Requirements

- A Mac with Apple silicon and macOS 27. Glifftop supports only the newest major macOS.
- A machine running Hyprland and `gliff-server` 0.4.3, which you can reach with
  `ssh <host>`. Glifftop asks ssh's questions in the window: a host key it doesn't know (Allow
  adds it to `~/.ssh/known_hosts`), a password, a key's passphrase or the host's own question.
  It never accepts a changed host key.

Tested with gliff-server 0.4.3 and Hyprland 0.56.2 on an NVIDIA RTX 3070 Ti (Vulkan Video
encode).

## Using it

1. Type the ssh destination, as you would after `ssh` (for example `omarchy`, a `Host` in
   your `~/.ssh/config`), pick the screen under **Options**, and connect. **Get Screens**
   lists the host's monitors. Each host you connect to is kept under **Machines**, with its
   options.

   <img src="docs/media/screen-choice.png" width="480" alt="The Glifftop window: the host omarchy, Options open with the Screen menu listing Focused Monitor, Virtual Screen and two monitors, and omarchy under Machines">
2. While the window is in front, the keyboard and pointer go to the remote computer;
   **Input ▸ Release Input** (⇧Esc) gives them back to the Mac.
3. **View ▸ Actual Size** (⌘0) shows the remote 1:1, turning Scale to Fit off; **View ▸ Scale
   to Fit** (⌥⌘0) scales a smaller screen up.
4. **Settings ▸ Clipboard**, or the clipboard button in the toolbar, shares the clipboard,
   after asking. While Glifftop is in front, what you copy on the Mac goes to the remote
   computer, and its copies come to the Mac. A password manager's copies go only at **Shared,
   including passwords**. The button steps through Not shared (grey), Shared (blue) and
   Shared including passwords (orange, with a key).
5. **File ▸ New Tab** (⌘T) opens another session as a tab; **New Window** (⌘N) opens one in
   a window of its own. A machine already open in another tab or window gets a virtual screen
   of its own. Input goes to the tab in front, and the host's focus follows it to that tab's
   screen: the pointer moves there (to where the Mac's pointer is over the picture, else to
   where the host's pointer was), so the window under it takes the keyboard. ⇧⌘[ and ⇧⌘]
   (the keys right of P, wherever the layout puts its brackets) move to the previous or next
   tab, or window, even while input is captured.

   Known limits:
   - An empty screen leaves the keyboard focus on another screen's window until you click or
     use a keybinding; Super+number still works there.
   - Glifftop doesn't fight focus changes made on the host: your own shortcut to another
     monitor, an app taking focus, or someone at the host.
   - Hyprland combines the modifiers of every keyboard, so two tabs to one host share their
     held keys; switching tabs lets go of the old tab's keys first.

## Build

You need Xcode 27.2 and its Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`,
or Xcode ▸ Settings ▸ Components). Then open `Glifftop.xcodeproj` and run, or:

```sh
xcodebuild -project Glifftop.xcodeproj -scheme Glifftop -configuration Debug \
    -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/Glifftop.app
```

To run the tests and checks, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Updating upstream

The protocol module is checked against golden fixtures that upstream's own Rust
(`gliff-proto`, pinned by commit in `tools/fake-server/Cargo.toml`) generates.

- `scripts/check-upstream.sh` says whether gliff has released a newer version.
- To adopt one: change the `rev` in `tools/fake-server/Cargo.toml` to that release's commit,
  run `scripts/cargo-net.sh update -p gliff-proto` and
  `scripts/cargo-net.sh fetch --locked`, then `scripts/test.sh`. The fixture drift check
  fails on every encoding that changed: review that diff, regenerate the fixtures (the
  command is in CLAUDE.md), and update the Swift side until the gate passes.

## Security

See [SECURITY.md](SECURITY.md) for what Glifftop trusts and how to report a vulnerability.

## License

MIT; see [LICENSE](LICENSE). Gliff's protocol is © its authors, MIT; see [NOTICE](NOTICE).
