# Glifftop (the app)

Two modules, as folders of this synchronized group, and the app's resources.

## The app icon

`AppIcon.icon` is an Icon Composer document (the target's App Icon, `AppIcon`), from which
Xcode builds every platform's icon and appearance. It is a lowercase g whose bowl frames a
tiled desktop:

- the background, a gradient set in `icon.json`, not an image;
- two groups of flat SVG layers on the full 1024 × 1024 canvas, numbered back to front: the
  g (`1-g.svg`), then the three tiles. Each layer is one shape in one colour, with its Dark
  colour in `icon.json`.

The SVGs carry no mask, shadow, gloss or blur: the system adds the shape and Liquid Glass,
with each group's shadow and translucency set in `icon.json`. Clear and Tinted are generated.
Edit the icon in Icon Composer (`open Glifftop/AppIcon.icon`), or preview it from the command
line with its `ictool` (into `.build/`, which git ignores):

```
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  Glifftop/AppIcon.icon --export-image --output-file .build/icon.png --platform macOS \
  --rendition Default --width 512 --height 512 --scale 1
```

## AppShell

The SwiftUI side of the app: the window, the connect form (the host, and a Screen picker:
Focused Monitor, Virtual Screen, then the host's monitors once Get Screens has listed them;
editing the host forgets the list), the session view, the streaming view (the picture below
the toolbar, never under it; `InterruptionView`, a dimmed picture under a glass panel, while
the server is quiet; the "Shift+Esc releases input" hint for a few seconds after capture; and
under the picture, with View ▸ Show Status Bar, `StatusBar`: the state, fps, Mbit/s, round
trip, chroma · encoder and the clipboard read, on the bar material, its height counted when
a mirror's window is fitted), the window's title (the host) and subtitle ("Virtual Screen ·
Connected", `SessionModel+Chrome.swift`), the toolbar (`SessionToolbar`, while a session is
shown, shown on hover in full screen: Screen and, on a virtual screen, Text Size; Share the
clipboard (`ClipboardToolbarItem`, asking first as Settings does, with the clipboard read
beside it); Connection Info, a popover of `StatsView`'s numbers and "The host draws W × H",
and Disconnect), the Connection menu (`ConnectionCommands`: Disconnect ⇧⌘D, Reconnect ⇧⌘R,
Connection Info ⌘I, Edit Machine… ⌘E), the View menu (Actual Size ⌘0, disabled on a virtual
screen; Scale to Fit ⌥⌘0; Show Status Bar ⌘/, app-wide, off by default; `ScreenMenus.swift`: Text Size, a virtual screen only, its steps
showing the remote scale on the window's display and the ones that change nothing off; and
Screen, the choice in use checked, "Focused Monitor (DP-2)" once the session names its
output, the listed monitors labelled as the form labels them (at most 60 characters), and
Refresh Screen List, while streaming, its error shown under it; the same screen again only
after the session ended; everything the menu reads changes only with its value, never with
the stats or a new StreamConfig (`hasPicture`, not `picture`), so Enter Full Screen isn't
lost), the Input menu (Release Input, ⇧⎋), Settings (`SettingsView`: the screen a
connection starts on, the virtual screen's text size (`TextSize`), Scale to Fit and
Share the clipboard (off by default; turning it on asks first; at once for an open session), in `UserDefaults` through
`AppSettings`) and (Debug builds) the Debug menu: Record 5 Seconds
and Test Cursor Shape (`TestCursor`'s crosshair in place of the session's shapes).

- **Owns:** `SessionModel` (one window's session, folded into a `SessionSnapshot`; the
  session's `PictureSlot` and the app's one `PictureRenderer`; the window's sizing, set once
  per session: `.fillScreen` for a virtual screen, else `.monitor` from the first view within
  the monitor (`SessionSnapshot.mirrorSize`); the window's Scale to Fit and text size, from Settings at each connection
  from the form and kept when the screen is switched; the video view's drawable and
  backing scale passed on as the session's `ViewTarget`; switching the session to another
  screen, a new session to the same host, in `SessionModel+Screens.swift`, the window staying
  in full screen meanwhile (`isSwitching`)), `ScreenList`
  (the host's monitors, listed through a lister closure, ssh by default, and never saved:
  one listing at a time, stopped (its error dismissed) when a session starts; a refresh keeps the list until the
  new one arrives; the list belongs to its host and is forgotten when the field names
  another, and a monitor is chosen only from its own host's list), the
  views, and the app's display text for GliffKit values, text sizes included
  (`DisplayNames.swift`; GliffKit carries no UI text). Among the views, `ClipboardReadView`
  shows the host's read of the Mac clipboard in the toolbar and the status bar: while it runs
  (reported after a second) with the bytes sent and Cancel
  (`SessionModel.cancelClipboardServing`), and for 3 s after a failure with why.
- **Imports:** SwiftUI, Observation, Foundation, UniformTypeIdentifiers, Metal (the system
  GPU for the renderer), `os` and the GliffKit modules. Must not import AppKit: anything
  AppKit goes through `MacPlatform`.

## MacPlatform

AppKit adapters for what SwiftUI can't do:

- the attached displays' size in pixels (`DisplayMetrics`);
- committing what a field holds before a form reads it, text still being composed or put
  there by AutoFill (`TextComposition`: commits the composition in place, tells the input
  method, and returns the field's own value; the SwiftUI binding may update later);
- quitting that waits for a session's Bye (`AppDelegate`, which knows only a `beforeQuit`
  closure; `GlifftopApp` hands it `SessionModel.shutdown`);
- the video view: `VideoNSView`, a `CAMetalLayer` (sRGB, opaque) that a display link draws
  into through `PictureRenderer` only when there is a new picture, a new drawable size or a
  new view box for the picture on screen, or Scale to Fit toggled, and only while the window
  is visible; wrapped for SwiftUI by `VideoView`. Once the window has been fitted for the
  session it reports its drawable size and backing scale (`onTarget`) on every change, from
  the display link, never from the connect form's window. Its cursor handling is in
  `VideoNSView+Cursor.swift`;
- `FullScreenTracker`: the window's full-screen state for `RootView`, which keeps its content
  resizable while full screen (fixed-size content makes the window ignore
  `toggleFullScreen`), and leaving full screen when the picture goes (not while View ▸ Screen
  reconnects), so the compact end screen isn't a box on black;
- `WindowSizer`: for a mirror (`WindowSizing.monitor`), the window at 1:1 for the monitor
  when that fits the screen, else the largest fitting size (`VideoFit.contentSize`), when
  streaming starts and on View ▸ Actual Size, never for a later view (the server shrinks a
  mirror to the window); for a virtual screen (`.fillScreen`), the screen's visible area when
  streaming starts. A full-screen window keeps its screen;
- input capture, keys and pointer together: `CaptureController` (one per window's session)
  feeds GliffInput's `InputController` the window, app, picture, link, sleep and lock
  changes, swallows the window's key events while captured (a local monitor, only while there
  is a picture), takes the pointer events `VideoNSView` hands it (`onPointer`), sends what it
  says through `Session.send`, and shows the Shift+Esc hint for 3 s; `CaptureTracker` tells it
  its window and the picture's state; `InputSource` reads the selected layout (HIToolbox's
  TIS) as the keymap text and whether the keyboard is ISO; `MacKeyEvent+NSEvent` and
  `PointerEvent+NSEvent` turn an `NSEvent` into values.
- the pointer: `VideoNSView` takes the mouse buttons, drags and scrolling over the picture,
  and motion from a tracking area while the window is key, only where this window is frontmost
  and its hit test finds the picture (not under an overlay or another window); a drag that
  began on the picture keeps sending, clamped to its edge. Each point goes in
  drawable pixels through `PointerMapper` with the fit the renderer draws with. A click that
  only brings the window forward isn't sent (no first mouse).
- the cursor: `RemoteCursor` makes what GliffInput's `CursorLook` chooses into an `NSCursor`
  (the remote's shape with a remote pixel the size of a picture pixel, or a hidden one), made
  again only for a new shape or size. `VideoNSView` shows it on entering the picture and on
  each move, and again under a resting pointer when capture, the session, the shape or its
  size on screen (seen by the display link) changes, once the window is key, the app active
  and no live resize is on. A drag follows it as motion does, back over the picture with the
  button still held (AppKit sends no `mouseEntered` during a drag). Off
  the picture, AppKit, the overlays and other windows set their own cursors (`cursorUpdate`
  goes to `super`). Whenever the pointer stops being the picture's (it moves onto an overlay
  or off the view, the window or app loses focus, the picture goes), the picture's cursor is
  given back as the arrow, but only while it is still the cursor shown (GliffInput's
  `CursorClaim`): one set since is left alone. Every set of the picture's own cursor goes
  through `showCursor`; the arrow (shown when released, or set on giving back) is never
  claimed. Each view has its own hidden cursor. The app's loss of focus is taken at
  `willResignActive`, while a cursor change still shows; regaining focus, the cursor is
  checked again under a resting pointer, as after a live resize or a move to another window.
  The view leaving its window gives back even mid-resize. `SessionModel` gives each session a
  new `CursorSlot`.

- the clipboard, Mac → remote (files aren't shared): `ClipboardController`
  (one per window's session) tells GliffClipboard's `ClipboardPolicy` when the session's
  window comes to the front or leaves it (the app active and the window key, from
  `ClipboardTracker`), when the pasteboard's `changeCount` moves (polled twice a second, in
  front or not) and when Share the clipboard or Include passwords changes, and carries out its offers and
  withdrawals through the session; it reads only the pasteboard's types. `PasteboardTypes`
  maps them to mime types (text, HTML, PNG or TIFF as `image/png`; a Finder copy only as its
  names in text) and finds password managers' concealed and transient marks: such a copy is
  offered only with Include passwords on (Settings, under Share the clipboard, disabled while
  it's off, asking first), and then with KDE's `x-kde-passwordManagerHint`, so the host's
  clipboard history skips it.
  `PasteboardSource` reads the data when the remote pastes, only from the copy the offer was
  made from, a TIFF converted to PNG with ImageIO, at most 32 MiB.

- the clipboard, remote → Mac: the host's offers reach the same policy, which
  puts them on the Mac while the window is in front, or holds them until it is back if the
  Mac's clipboard hasn't moved since. `RemotePasteboard` writes one item with its text, HTML
  and PNG, each fetched only when a Mac app pastes it, a remote password marked concealed;
  files alone write nothing. `PasteProvider` fetches while it runs the event loop, so
  Glifftop keeps drawing and Cancel works, and returns no data once the session has ended,
  sharing is off or the app is quitting (`AppDelegate` cancels a running paste first), nor
  for a second paste while one runs. `PasteProgressPanel` floats over the app being pasted
  into after a second: what is coming, the bytes so far and Cancel, or why it failed.

- **Imports:** AppKit, Carbon (HIToolbox's input sources and keyboard type), Metal,
  QuartzCore, CoreGraphics, ImageIO and UniformTypeIdentifiers (TIFF to PNG), Foundation, `os`, Synchronization (`PasteProvider`'s outcome), Observation, the GliffKit modules, and SwiftUI
  only for `NSViewRepresentable` wrappers. Must not use AppShell's views; AppShell calls in,
  never the reverse.
