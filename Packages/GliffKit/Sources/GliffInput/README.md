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
  on every way input can leave; `releaseAllKeys()` and `releaseAllButtons()` let go of the
  keys alone or the buttons alone.
- **`MacKeyEvent`, `MacModifierFlags`, `MacKeyTranslator`:** a Mac key event as values, and
  what it means (`KeyAction`): press, release, a Caps Lock toggle, Shift+Esc (release the
  keyboard; Esc is never sent), or nothing (repeats, Fn, unknown keys). A modifier's state
  comes from its own device-dependent bit, so left and right stay apart; with only the shared
  bit (software-posted events), one side.
- **`InputCapture`:** when keys and the pointer go to the remote (one capture for both), in
  either `CaptureMode`: `.integrated` ("Integrated", the default) or `.confined` ("Capture").
  Both capture while the window is key, the app active, the picture showing, the link live
  and no overlay (an open menu, or the Ports popover over the window) holds it off, unless
  Shift+Esc released it (until the picture is clicked; a new picture starts captured), which
  `isReleased` says. A `quiet` rise (a window the app made key again itself) is no activation.
  `isReleasable`: captured, or held off only by an overlay (any menu, Release Input's own
  among them, or the popover). In `.confined`, the pointer is confined once it enters the
  picture (`.pointerOnPicture(true)`, or the click that takes input back when the last report
  has the pointer on the picture, not beside it), until capture falls, a suspension
  (`.pointerOnPicture(false)`), `.away`, a mode change or a new picture; the app reports the
  pointer's place again after each. `apply` returns a `CaptureChange`: `activates` on a rise
  of capture, except at an overlay's close when nothing else changed under it (a mode change
  never moves capture), and `showHint` on the first capture or switch to it while captured
  (Integrated) or the first confinement (Capture) of each picture and after each release.
- **`PointerPlace`:** where a ⌘ event happened for Integrated's routing (`classify`): the
  picture (its video view, or a drag from it), the chrome (the rest of the key session
  window, a window attached to it, or the menu bar's strip elsewhere), or outside. The app's
  probe gathers its `Facts`.
- **`PointerEvent`:** a pointer event over the picture, with its position in remote
  coordinates: motion, a button by `NSEvent.buttonNumber`, a scroll; a button or scroll carries
  its modifier flags.
- **`InputController`:** the one object the app drives per session. Not captured, keys and the
  pointer pass through untouched, except a click on the picture when only Shift+Esc holds
  capture off: it takes input back, and nothing from the pointer is sent until its button is
  up (forgotten if capture ends, or on sleep or a lock); captured, every key and pointer event
  is swallowed (⌘ chords included) and translated, keys and buttons through the ledger, except
  a key-up the remote never had pressed, which goes on to the Mac. In Integrated, an event
  with ⌘ in its flags that would reach the remote (a fresh key-down, a modifier's press, a
  held key's release, a Caps Lock toggle) asks the app (`key(_:overChrome:)`, at most once)
  whether the pointer is over Glifftop's chrome. There a key-down goes to the Mac after the
  remote lets go of every key it holds (`releaseAllKeys()`), its repeats and key-up after it
  (`MacChordKeys`; a repeat with ⌘ let go goes nowhere); a modifier's press goes to the Mac;
  a release or toggle goes to the remote without pressing Super. Capture asks nothing. Presses
  and scrolls carry their position: one away from where the remote pointer was left moves it
  there first (always after a captured key or the end of capture, which may have moved it),
  and the recapturing click's up moves it to where it was let go. Capture ending mid-scroll
  stops the precise axes that scrolled. Before a click, a scroll or a key that sends something
  (not motion, a repeat or an unheld release), the held modifiers are synced from its flags
  (`InputController+Modifiers.swift`): those the remote holds that are up are let go, last
  pressed first, then those held that it lacks are pressed, wherever they were pressed; a
  modifier's own event is left to itself. A repeat, Fn, an unknown key or an unheld release
  still lets go of the stale ones. A release can trigger a binding that moves the host's
  pointer, so any forgets where it was. On a click or scroll: the modifiers, the motion, then
  the button or scroll. Every way capture ends (and `.away`: sleep, lock) releases what the
  remote holds, an open menu's included. A result's `activates` says the host's focus should
  follow (`activate(at:)`). A keymap is sent only when its text changes.
  Confined (`InputController+Confined.swift`, Capture mode once the pointer entered the
  picture): the app's logical deltas (`pointerMoved`) move a `VirtualPointer`, absolute motion
  sends nothing, and clicks and scrolls land at the virtual position; the host's CursorPos
  (`hostPointer`) moves it when it is a warp, not an echo. It starts hidden where the host's
  last report hid its pointer (`confine(hostHiddenAt:)`), and after `hostPictureChanged` (or
  `confine(newPicture:)`, the last report a new picture's announcement) a
  report waits until the new picture is drawn (at most `newPictureLimit`), as it is in that
  picture's pixels; `pictureDrawn` ends the wait and follows the last report skipped.
  `followHost` is one tick: the reports since the last (nil: a new picture), then the picture
  drawn. Confinement ends whenever
  `isConfined` falls, leaving its place in `unconfinedAt` for the app to put the Mac cursor
  there; still captured (a suspension), a precise scroll under way stops and the buttons held
  come up, as their stop and releases may go
  elsewhere. A recapturing click's drag moves it but sends nothing until the up.
- **`StartWarp`:** the first motion after the app warps the Mac pointer to the view's centre
  to confine it: the warp's displacement taken out when the delta comes within a quarter of
  the warp's length (or 1 point) of it.
- **`VirtualPointer`:** the confined pointer's logical place: deltas clamped to the output, and
  the host's reports, of which one within 1.5 on both axes of a position sent in the last
  second (at most 1024 kept, a 1 kHz mouse's second, each as the host rounds it) or of the
  current one is an echo, any other a warp it adopts. A hidden report only hides it, and the
  first shown one at the place it hid is no warp (upstream's Enter re-sends it). It starts
  with the absolute motions sent just before (the entry's, the activation's nudge) as its own.
  A new size clamps it (a virtual screen resized keeps its coordinates); the same output
  fitted into a new stream size scales it and them.
- **`XKBLayout`, `XKBKeymap`:** an xkeyboard-config layout and variant, and the include-only
  keymap text a Keymap carries (`pc+<symbols>+inet(evdev)`, with `numpad(mac)` types so the
  keypad types digits with no NumLock), compiled by the server. The app sends Hello with no
  keymap: one the server can't compile would fail its setup, a failed Keymap is ignored.
- **`PointerMapper`, `PictureRect`, `PictureGeometry`:** a point over the drawn picture to the
  remote's logical coordinates (upstream `to_remote`): undo the fit, stretch the view box to
  the stream, clamp to its edges, divide by the remote scale. `remoteDelta` scales a delta the
  same way, without the clamp; `local` is the inverse, a logical point to backing pixels.
- **`FocusTarget`:** where a window's activation puts the remote pointer, in logical
  coordinates: the Mac pointer over the uncovered picture, else the remote cursor's last
  position, hidden or not (capture-buffer pixels, converted and clamped), else the centre;
  none before there is a picture.
  `InputController.activate(at:)` sends it while captured as two motions a pixel apart, so the
  host's focus follows.
- **`MonitorHandover`, `HandoverFacts`, `HandoverPointer`:** when the pointer resting on
  another window's picture brings that window in front. Each window's facts are gathered the
  same way: the key window must be a mirror captured in Integrated, its picture live, not
  released (`canLeave`, checked first); the other a live Integrated mirror of the same
  destination, not released, no sheet. The pointer's: the app active, no button held, over the
  other's picture (not its bars), that window frontmost there. Counted 100 ms from the first
  such motion (only a motion starts it; a new window restarts it), it answers `handOver` once
  per entry; an exit, a button, a key change (`keyChanged(to:)`: the key window is never its
  own target) or a failed condition at a motion or a tick cancels it; a motion over another
  window covered at the pointer (mirrors overlap) changes nothing. Times are `Duration`s since an origin the caller picks.
- **`HandoverEntry`:** where a handover's pointer entered the other window's picture, that
  window's next activation target in place of the Mac pointer: used once, and gone after 500 ms.
- **`TabChord`:** ⌘⇧[ and ⌘⇧] (no ⌃ or ⌥), the previous and next Glifftop tab, once per
  press. `TabChordKeys` follows them as they come: the chord's own repeats and key-up are
  swallowed with it; a bracket pressed before ⌘⇧ passes, its release too; a new press of the
  chord's key (its key-up went to the window the chord moved to) passes, its release too.
- **`QuitHold`:** the ⌘Q guard's timing, from values and with no clock: a first press shows the
  message, ⌘ and the key held 1 s (confirmed by the keys' real state at the tick) quits,
  letting go early leaves the message 1.5 s (late, after the second, quits), a fresh press
  while it shows quits, repeats change nothing. `nextDeadline` says when the caller's timer
  is due.
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
  cursor is drawn into the picture), else the arrow; confined, hidden (the app draws the
  virtual pointer with the captured look, nothing when the video carries the pointer);
  released, the arrow.
- **`CursorClaim`:** the cursor the picture last showed. When the pointer stops being the
  picture's, the arrow replaces it only if it is still the cursor shown (by identity), never
  one set since by the toolkit, an overlay or another window; not during a live resize. Every
  set of the picture's cursor goes through `show`; the system arrow is never claimed.
- **`KeyboardLayoutTable`:** macOS input source ids to XKB layouts: the Mac variant where one
  exists, so the remote types what the keycaps show; otherwise the layout that types the same,
  matched key by key (plain and shifted) against xkeyboard-config; `us` when unknown.
