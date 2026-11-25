# GliffInput

Owns the input rules: what a key or pointer event on this device means to the remote, what
the remote holds, and when input is captured. Values in, values out: no I/O beyond logging.

- **Imports:** GliffProtocol, Foundation, `os` (Logger), `Synchronization`. Must not import
  AppKit, UIKit, SwiftUI, GliffVideo, GliffTransport or GliffSession. Platform adapters (the
  app's MacPlatform today; touch or iOS later) turn their events into this module's values.
- **`MacKeyCode`:** Mac virtual key codes (kVK) to evdev codes, by position, with the ISO
  correction (`positional`). Fn is never sent; an unknown code is logged once.
- **`InputMessage`:** what the rules send (a key, a keymap, pointer motion, a pointer button,
  a scroll), with its `ClientMessage`.
- **`InputLedger`:** the keys and pointer buttons the remote holds. A release goes out only for
  what is held; a fresh press of something held releases it first (its release was missed);
  `releaseAll()` lets go of everything (buttons, then keys, each last pressed first) and runs
  on every way input can leave.
- **`MacKeyEvent`, `MacModifierFlags`, `MacKeyTranslator`:** a Mac key event as values, and
  what it means (`KeyAction`): press, release, a Caps Lock toggle, Shift+Esc (release the
  keyboard; Esc is never sent), or nothing (repeats, Fn, unknown keys). A modifier's state
  comes from its own device-dependent bit, so left and right stay apart; with only the shared
  bit (software-posted events), one side.
- **`InputCapture`:** when keys and the pointer go to the remote (one capture for both), in
  either `CaptureMode`: `.integrated` ("Integrated", the default) or `.confined` ("Capture").
  Both capture while the window is key, the app active, the picture showing, the link live
  and no menu open, unless Shift+Esc released it (until the picture is clicked; a new picture
  starts captured). In `.confined`, the pointer is confined once it enters the picture
  (`.pointerOnPicture(true)`, or the click that takes input back), until capture falls, a
  suspension (`.pointerOnPicture(false)`), `.away`, a mode change or a new picture; the app
  reports the pointer's place again after each. `apply` returns a `CaptureChange`:
  `activates` on a rise of capture, except at a menu's close when nothing else changed under
  the menu (a mode change never moves capture), and `showHint` on the first capture or switch
  to it while captured (Integrated) or the first confinement (Capture) of each picture and
  after each release.
- **`PointerEvent`:** a pointer event over the picture, with its position in remote
  coordinates: motion, a button by `NSEvent.buttonNumber`, a scroll; a button or scroll carries
  its modifier flags.
- **`InputController`:** the one object the app drives per session. Not captured, keys and the
  pointer pass through untouched, except a click on the picture when only Shift+Esc holds
  capture off: it takes input back, and nothing from the pointer is sent until its button is
  up (forgotten if capture ends, or on sleep or a lock); captured, every key and pointer event
  is swallowed (⌘ chords included) and translated, keys and buttons through the ledger. Presses
  and scrolls carry their position: one away from where the remote pointer was left moves it
  there first (always after a captured key or the end of capture, which may have moved it),
  and the recapturing click's up moves it to where it was let go. Capture ending mid-scroll
  stops the precise axes that scrolled. Before a click, a scroll or a key that sends something
  (not motion, a repeat or an unheld release), the held modifiers are synced from its flags
  (`InputController+Modifiers.swift`): those the remote holds that are up are let go, last
  pressed first, then those held that it lacks are pressed, wherever they were pressed; a
  modifier's own event is left to itself. A repeat, Fn, an unknown key or an unheld release
  still lets go of the stale ones. On a click or scroll: the modifiers, the motion, then the
  button or scroll. Every way capture ends (and `.away`: sleep, lock) releases what the
  remote holds, an open menu's included. A result's `activates` says the host's focus should
  follow (`activate(at:)`). A keymap is sent only when its text changes.
- **`XKBLayout`, `XKBKeymap`:** an xkeyboard-config layout and variant, and the include-only
  keymap text a Keymap carries (`pc+<symbols>+inet(evdev)`, with `numpad(mac)` types so the
  keypad types digits with no NumLock), compiled by the server. The app sends Hello with no
  keymap: one the server can't compile would fail its setup, a failed Keymap is ignored.
- **`PointerMapper`, `PictureRect`, `PictureGeometry`:** a point over the drawn picture to the
  remote's logical coordinates (upstream `to_remote`): undo the fit, stretch the view box to
  the stream, clamp to its edges, divide by the remote scale.
- **`FocusTarget`:** where a window's activation puts the remote pointer, in logical
  coordinates: the Mac pointer over the uncovered picture, else the remote cursor's last
  position, hidden or not (capture-buffer pixels, converted and clamped), else the centre;
  none before there is a picture.
  `InputController.activate(at:)` sends it while captured as two motions a pixel apart, so the
  host's focus follows.
- **`TabChord`:** ⌘⇧[ and ⌘⇧] (no ⌃ or ⌥), the previous and next Glifftop tab, once per
  press. `TabChordKeys` follows them as they come: the chord's own repeats and key-up are
  swallowed with it; a bracket pressed before ⌘⇧ passes, its release too; a new press of the
  chord's key (its key-up went to the window the chord moved to) passes, its release too.
- **`PointerButtons`:** `NSEvent.buttonNumber` 0–7 to evdev `BTN_LEFT`, `BTN_RIGHT`,
  `BTN_MIDDLE`, then `BTN_SIDE` (back) on to `BTN_TASK`; other buttons send nothing.
- **`ScrollEvent`, `ScrollPhase`, `ScrollTranslator`:** Mac scrolling to Gliff's axes
  (after upstream `scroll_delta`): the sign flipped, precise deltas as points, a wheel event as
  its accelerated delta in whole steps (1–100) of 15 with the step count as `discrete`, a
  gesture's end as its distance and then a stop on both axes; momentum and a gesture that may
  begin are dropped.
- **`CursorImage`:** a remote cursor shape the app can show, checked strictly: each
  side 1–1024, the payload exactly `width × height × 4` premultiplied BGRA bytes, the hotspot
  inside. A shape with nothing to show (all clear, or one colour) is valid but not visible.
  Either way the app shows the arrow (nothing when the video carries the pointer).
  `pointsPerPixel` sizes it so a remote pixel matches a picture pixel on screen (nil without
  sizes).
- **`CursorLook`:** what the pointer looks like over the picture: the remote's visible shape at
  its size only while captured; captured without one, hidden when the video carries the
  pointer (`videoHasPointer`: a virtual screen, this session's or another's mirrored, or a
  monitor of Hyprland's headless backend named `HEADLESS-N`, such as a container's, whose
  cursor is drawn into the picture), else the arrow; released, the arrow.
- **`CursorClaim`:** the cursor the picture last showed. When the pointer stops being the
  picture's, the arrow replaces it only if it is still the cursor shown (by identity), never
  one set since by the toolkit, an overlay or another window; not during a live resize. Every
  set of the picture's cursor goes through `show`; the system arrow is never claimed.
- **`KeyboardLayoutTable`:** macOS input source ids to XKB layouts: the Mac variant where one
  exists, so the remote types what the keycaps show; otherwise the layout that types the same,
  matched key by key (plain and shifted) against xkeyboard-config; `us` when unknown.
