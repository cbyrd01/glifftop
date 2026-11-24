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

The SwiftUI side of the app: the window, the machines (`MachinesView`: "Connect to a host",
a field and Connect, with Options set before the first connection, `MachineOptionsForm`: a
Screen picker (Focused Monitor, Virtual Screen, then the host's monitors once Get Screens has
listed them, and a saved machine's monitor though not listed; editing the host forgets the
list), a virtual screen's Text Size and Resolution, Scale to Fit and Reconnect automatically,
from Settings, or from the saved machine the field names; then the saved machines: name, host
and screen, when last connected and a favourite's star, double-click or Return connecting, and
a menu of Connect, Edit…, Favourite and Remove, which asks), the machine sheet
(`EditMachineView`: Name, Host and the options; New Machine… ⌥⌘N and the + button add one and
can Connect, Connection ▸ Edit Machine… ⌘E edits the session's; a machine shown in any window
keeps its host), the windows and tabs (`SessionWindow`: each window or native tab its own
`SessionModel` and session, opened from a `TabRequest`; File ▸ New Tab ⌘T joins the key
window's tab group, New Window ⌘N opens one alone, Close Window ⇧⌘W closes every tab, and
closing a tab ends its session as Disconnect does; `OpenSessions`, the open windows' models;
a host already open elsewhere starts on a virtual screen, which its machine never keeps
(`TabPlanning`); the menus act on the key window's model, `FocusedSession.swift`), the session view, the streaming view (the picture below
the toolbar, never under it; `InterruptionView`, a dimmed picture under a glass panel, while
the server is quiet, with Disconnect and Reconnect Now; `ReconnectingView`, the last picture
dimmed under a glass panel while a lost session is tried again: why it ended, the countdown
and the try, Reconnect Now and Disconnect; the "Shift+Esc releases input" hint for a few seconds after capture; and
under the picture, with View ▸ Show Status Bar, `StatusBar`: the state, fps, Mbit/s, round
trip, chroma · encoder and the clipboard read, on the bar material, its height counted when
a mirror's window is fitted), the window's title (the machine's name, else the host; numbered from a machine's second tab
in the window, "omarchy 2") and subtitle ("Virtual Screen ·
Connected", `SessionModel+Chrome.swift`), the toolbar (`SessionToolbar`, while a session is
shown, shown on hover in full screen: Screen and, on a virtual screen, Text Size; the
clipboard (`ClipboardToolbarItem`: one button stepping through Not shared, Shared and Shared
including passwords, each step up asking first as Settings does, with the clipboard read
beside it); Connection Info, a popover of `StatsView`'s numbers and "The host draws W × H",
and Disconnect), the Connection menu (`ConnectionCommands`: Disconnect ⇧⌘D, Reconnect ⇧⌘R,
Connection Info ⌘I, Edit Machine… ⌘E; and File's New Tab, New Window, New Machine… and Close
Window), the View menu (Actual Size ⌘0, disabled on a virtual
screen, turning Scale to Fit off; Scale to Fit ⌥⌘0; Show Status Bar ⌘/, app-wide, off by default; `ScreenMenus.swift`: Text Size, a virtual screen only, its steps
showing the remote scale on the window's display and the ones that change nothing off;
Resolution, a virtual screen only: Automatic, Retina and Standard, Standard off on a display
under 2×, a Standard picture drawn scaled to the window (`drawsScaled`, from the stream in
hand); and
Screen, the choice in use checked, "Focused Monitor (DP-2)" once the session names its
output, the listed monitors labelled as the form labels them (at most 60 characters), and
Refresh Screen List, while streaming, its error shown under it; the same screen again only
after the session ended; everything the menu reads changes only with its value, never with
the stats or a new StreamConfig (`hasPicture`, not `picture`), so Enter Full Screen isn't
lost), the Input menu (Release Input, ⇧⎋), Settings (`SettingsView`: the options a
new host or machine starts from (`AppSettings.defaultOptions`: the screen, the virtual
screen's text size (`TextSize`) and resolution, Scale to Fit, Reconnect automatically) and
the clipboard (`ClipboardSharing`: Not shared by default, Shared, or Shared including passwords; a
step up asks first; at once for an open session following Settings. A machine may have its
own, which the options form and the toolbar's button set; Settings' doesn't override it, and
every window to the machine follows it), in `UserDefaults` through
`AppSettings`) and (Debug builds) the Debug menu: Protocol Inspector (⌥⌘I: `InspectorView`, a
section per open window titled as its tab, with each message type's count, bytes, last seen
and rate per direction, and the last 200 messages, refreshed once a second, with Pause and
Clear; `InspectorModel` holds a `ProtocolTally` per window behind a `Mutex`, filled by the
session's `ProtocolObserver`: types and sizes only, never a body), Record 5 Seconds
and Test Cursor Shape (`TestCursor`'s crosshair in place of the session's shapes).

- **Owns:** `MachineStore` (the saved machines in `UserDefaults`, key `machines`, as
  GliffMachines' JSON); `SessionModel` (one window's session, its machine (the destination's
  when it starts; recorded, with the window's options and the date, when it first streams, so
  a host that never streams isn't saved; View-menu changes of screen, text size, resolution
  and Scale to Fit kept on it, `SessionModel+Machines.swift`), folded into a `SessionSnapshot`; the
  session's `PictureSlot` and the app's one `PictureRenderer`, the picture not shown while the
  session holds it (`SessionSnapshot.holdsPicture`, "Waiting for video" meanwhile, or a
  reconnect's last picture); the window's sizing, set once per session: `.fillScreen` for a
  virtual screen (from the start), else `.monitor` from the first view within
  the monitor (`SessionSnapshot.mirrorSize`); the window's Scale to Fit, text size, resolution and reconnect, from the machine's
  options at each connection and kept when the screen is switched; the video view's drawable and
  backing scale passed on as the session's `ViewTarget`, with the window's live resize;
  switching the session to another
  screen, a new session to the same host, in `SessionModel+Screens.swift`, the window staying
  in full screen meanwhile (`isSwitching`); a lost session tried again with backoff
  (`SessionModel+Reconnect.swift`, GliffSession's `Reconnector`): a session that streamed and
  ended with a reason a retry may fix, Reconnect automatically on, each try a new session in
  the same window, its size and full screen kept; Disconnect, closing the window, quitting,
  another connection or Reconnect automatically turned off stops it (the last, with why it was
  lost on the end screen); `SessionEndedView` after
  an end the person didn't choose, with Try Again, Edit Machine… and Close: Disconnect and
  Cancel go straight back to the machines), `AppConnections` (the app's one `HostConnections`:
  each session and Get Screens is a channel on its host's one signed-in ssh), `ScreenList`
  (the host's monitors, listed through a lister closure, by default on the host's shared
  connection, and never saved:
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
- quitting that waits for the sessions' Bye (`AppDelegate`, which knows only a `beforeQuit`
  closure; `GlifftopApp` hands it `OpenSessions.shutdownAll`, then `AppConnections.closeAll`),
  and closing the last window quits;
- native tabs (`WindowTabbing`): a SwiftUI window is already ordered in when its content
  reaches it, so a new tab joins its group with `addTabbedWindow`, after the group's last tab,
  and a window opened alone that macOS tabbed anyway leaves its group; it reports the window's
  number and its group's in tab order (KVO on the group's windows) and the window's close;
  Close Window closes every tab of the key window's group;
- switching tabs (`TabSwitcher`): Window ▸ Previous Tab and Next Tab (⇧⌘[, ⇧⌘]), and the same
  chord over the picture, taken by `CaptureController`'s key monitor before the remote (while
  captured, too), select the window's previous or next tab; in a window of one tab, the
  previous or next session window in opening order (a group once, as its selected tab), whose
  Space comes forward;
- the video view: `VideoNSView`, a `CAMetalLayer` (sRGB, opaque) that a display link draws
  into through `PictureRenderer` only when there is a new picture, a new drawable size or a
  new view box for the picture on screen, or Scale to Fit toggled, and only while the window
  is visible; wrapped for SwiftUI by `VideoView`. Once the window has been fitted for the
  session it reports its drawable size and backing scale (`onTarget`) on every change, from
  the display link and as a live resize ends, never from the machines window. Its cursor handling is in
  `VideoNSView+Cursor.swift`;
- `WakeObserver`: the Mac waking (`NSWorkspace.didWakeNotification`) and whether the network
  path is usable (`NWPathMonitor`), for the session's probe and its reconnect;
- `FullScreenTracker`: the window's full-screen state for `RootView`, which keeps its content
  resizable while full screen (fixed-size content makes the window ignore
  `toggleFullScreen`), and leaving full screen when the picture goes (not while View ▸ Screen
  or a lost session reconnects, nor while a virtual screen's session awaits its picture), so
  the compact end screen isn't a box on black;
- `WindowSizer`: for a mirror (`WindowSizing.monitor`), the window at 1:1 for the monitor
  when that fits the screen, else the largest fitting size (`VideoFit.contentSize`), when
  streaming starts and on View ▸ Actual Size, never for a later view (the server shrinks a
  mirror to the window); for a virtual screen (`.fillScreen`), the screen's visible area as
  the session starts (`SessionAreaTracker`), and again when streaming starts. A full-screen window keeps its screen. A window with other tabs keeps the
  group's size: no session sizes it, a mirror draws fitted (`SessionModel.sharesWindow`), the
  machines stay resizable and Actual Size is off; a mirror left alone (torn off) is fitted
  again;
- `LiveResizeTracker`: the window's live resize (a drag of its edge), for
  `SessionModel.liveResizeChanged`, which tells the session (no Resize during one) and any
  session started during one. It reports the end a turn after AppKit's, once the video view
  (or `SessionAreaTracker`) has laid out and reported the size it ended on, and when it
  leaves its window;
- `SessionAreaTracker`: a virtual screen's window before its picture, filled once and
  measured as the video view will be (`NSView.backingPixels`, less the status bar), so the
  remote screen is asked for that size while the session connects;
- input capture, keys and pointer together: `CaptureController` (one per window's session)
  feeds GliffInput's `InputController` the window, app, picture, link, sleep and lock
  changes, swallows the window's key events while captured (a local monitor, only while there
  is a picture), takes the pointer events `VideoNSView` hands it (`onPointer`), sends what it
  says through `Session.send`, and shows the Shift+Esc hint for 3 s. Capture turning on (the
  window or tab coming to the front, the first picture, recapture) is an activation, as are a
  wake, an unlock and a user switch back while captured: before anything else, two motions
  onto `SessionModel.activationTarget` (`VideoNSView`'s Mac pointer over the uncovered picture, else the
  session's `RemotePointerSlot`, else the centre: `FocusTarget`), so the host's focus follows
  to the tab's screen. `CaptureTracker` tells it
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
  front or not) and when the clipboard's sharing changes, and carries out its offers and
  withdrawals through the session; it reads only the pasteboard's types. `PasteboardTypes`
  maps them to mime types (text, HTML, PNG or TIFF as `image/png`; a Finder copy only as its
  names in text) and finds password managers' concealed and transient marks: such a copy is
  offered only while it's Shared including passwords, and then with KDE's `x-kde-passwordManagerHint`, so the host's
  clipboard history skips it. A host's copy one window put on the Mac (`ClipboardOrigin`
  remembers which destination's) is never offered back to that destination by another
  window; another host's window offers it, host to host.
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
