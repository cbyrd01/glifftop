# Glifftop (the app)

Two modules, as folders of this synchronized group, and the app's resources. The app icon,
`AppIcon.icon`, is described in [CONTRIBUTING.md](../CONTRIBUTING.md#the-app-icon).

## The askpass helper

`glifftop-askpass/` (beside this folder) is the `glifftop-askpass` tool target: one `main`
calling `AskpassHelper.run()`. The app's Copy Files phase signs it into
`Glifftop.app/Contents/Helpers`, and ssh runs it to ask its sign-in questions through the app.

- **Owns:** nothing but that `main`; its settings are `Config/GlifftopAskpass.xcconfig` (no
  entitlements, no sandbox).
- **Imports:** Foundation and GliffKit's `GliffAskpass`, never the app's modules or any other
  GliffKit library.

## AppShell

The SwiftUI side of the app.

- **The machines** (`MachinesView`): "Connect to a host", a field and Connect, with Options set
  before the first connection, from Settings or from the saved machine the field names
  (`MachineOptionsForm`: a Screen picker of Focused Monitor, Virtual Screen, then the host's
  monitors once Get Screens has listed them, and a saved machine's monitor though not listed,
  editing the host forgetting the list; a virtual screen's Text Size and Resolution; Scale to
  Fit; Reconnect automatically). Then the saved machines: name, host and screen, when last
  connected and a favourite's star; double-click or Return connects; a menu of Connect, Edit…,
  Favourite and Remove, which asks.
- **The machine sheet** (`EditMachineView`): Name, Host and the options. New Machine… (⌥⌘N) and
  the + button add one and can Connect; Connection ▸ Edit Machine… (⌘E) edits the session's. A
  machine shown in any window keeps its host.
- **Windows and tabs** (`SessionWindow`): each window or native tab has its own `SessionModel`
  and session, opened from a `TabRequest`. File ▸ New Tab (⌘T) joins the key window's tab group,
  disabled while that window shows one of its model's sheets; New Window (⌘N) opens one alone;
  Close Window (⇧⌘W) closes every tab; closing a tab ends its session as Disconnect does.
  `OpenSessions` holds the open windows' models. A host already open elsewhere starts on a
  virtual screen, which its machine never keeps (`TabPlanning`). The menus act on the key
  window's model (`FocusedSession.swift`).
- **The streaming view:** the picture below the toolbar, never under it.
  - `InterruptionView`: a dimmed picture under a glass panel while the server is quiet, with
    Disconnect and Reconnect Now.
  - `ReconnectingView`: the last picture dimmed under a glass panel while a lost session is
    tried again: why it ended, the countdown and the try, Reconnect Now and Disconnect.
  - `InputHintView`, for a few seconds: in Integrated "⌘ shortcuts work over the toolbar ·
    Shift+Esc releases input" after capture, in Capture "Shift+Esc frees the pointer and
    keyboard" after confinement.
  - `StatusBar`, under the picture with View ▸ Show Status Bar: the state, fps, Mbit/s, round
    trip, chroma · encoder, the newest port notice (`PortsNoticeBar`) and the clipboard read, on
    the bar material. Its height counts when a mirror's window is fitted.
- **The title** (`SessionModel+Chrome.swift`): the machine's name, else the host, numbered from
  a machine's second tab in the window ("omarchy 2"); the subtitle "Virtual Screen · Connected".
- **The toolbar** (`SessionToolbar`, while a session is shown; on hover in full screen): Screen
  and, on a virtual screen, Text Size; the clipboard; Ports; Connection Info, a popover of
  `StatsView`'s numbers and "The host draws W × H"; and Disconnect.
  - `ClipboardToolbarItem`: one button stepping through Not shared, Shared and Shared including
    passwords, each step up asking first as Settings does, with the clipboard read beside it.
  - `PortsToolbarItem`: the `network` symbol, with a badge counting the forwards listening on
    this Mac, else a dot for an offer the popover hasn't shown.
  - `PortsPopover`: Forwarded, Available, From ssh config (each line not applied, and why),
    Other ports, Forward a Port… and "Forward new ports automatically". Each forward's row
    (`PortsForwardRow`) has Open or Try Again and a menu of Open in Browser, Copy Address,
    Forward When Connected (the machine's; disabled for a host not saved) and Stop. Every
    address is `localhost:P` on both loopbacks, `127.0.0.1:P` on IPv4 alone.
  - `PortsNoticeCapsule`: while the status bar is hidden, a new notice also shows for 8 s as a
    glass capsule over the picture's bottom edge, with its buttons and Dismiss.
- **The Connection menu** (`ConnectionCommands`): Disconnect (⇧⌘D), Reconnect (⇧⌘R), Connection
  Info (⌘I), Show Ports (⌥⌘P; `PortsCommands`: the popover, or a sheet with the same content
  while the toolbar isn't shown), Edit Machine… (⌘E) and `ShowAllMonitorsMenu`. Its Show All
  Monitors ▸ Show as Tabs and Show as Windows are enabled while the key window streams over a
  live link with nothing listing, Show as Tabs not while the window shows one of its sheets (the
  Ports sheet included). Place Windows in the Host's Order is Settings' "Place monitor windows
  in the host's order" (`AppSettings.placeMonitorWindowsKey`, off by default). File has New Tab,
  New Window, New Machine… and Close Window.
- **Show All Monitors** (`SessionModel+Monitors.swift`):
  - Each press lists the host's monitors afresh through the window's `ScreenList`, whose
    completion always runs, cancelled when a session starts. The answer is dropped unless the
    window still streams that destination.
  - `MonitorPlanning` picks the monitors no window to the destination shows, counting
    `OpenSessions.shown(for:)`'s live mirrors, a Focused Monitor mirror not yet named as the
    focused monitor, and its ended named mirrors, which start again in place.
  - Each other monitor opens by name with the window's options, in a window or tab from a
    `TabRequest` whose `WindowStart` connects it as it opens, its screen its own, carrying the
    source's input mode and `joined`.
  - With the placement setting on, Show as Windows gives each window its `MonitorPlacement` slot
    (a display and a cascade step), counting the windows already showing a monitor. It moves the
    key window to its own slot when it is a mirror of a listed monitor alone in its window and
    not in full screen (`WindowPlacement.move`, then `WindowSizer.fit`).
  - It alerts on the window when the listing fails, the host has no monitors, or every one is
    shown.
- **The View menu:** Actual Size (⌘0; disabled on a virtual screen; turns Scale to Fit off),
  Scale to Fit (⌥⌘0), Show Status Bar (⌘/; app-wide, off by default), and `ScreenMenus.swift`:
  - Text Size, a virtual screen only: its steps show the remote scale on the window's display,
    the ones that change nothing off.
  - Resolution, a virtual screen only: Automatic, Retina and Standard, Standard off on a display
    under 2×. A Standard picture is drawn scaled to the window (`drawsScaled`, from the stream
    in hand).
  - Screen: the choice in use checked, "Focused Monitor (DP-2)" once the session names its
    output, the listed monitors labelled as the form labels them (at most 60 characters), and
    Refresh Screen List while streaming, its error shown under it. The same screen again only
    after the session ended. Everything the menu reads changes only with its value, never with
    the stats or a new StreamConfig (`hasPicture`, not `picture`), so Enter Full Screen isn't
    lost.
- **The Input menu:** the key window's mode, Integrated or Capture, as radio items, then Release
  Input (⇧⎋).
- **Settings** (`SettingsView`, in `UserDefaults` through `AppSettings`):
  - the options a new host or machine starts from (`AppSettings.defaultOptions`: the screen, a
    virtual screen's text size (`TextSize`) and resolution, Scale to Fit, Reconnect
    automatically);
  - the clipboard (`ClipboardSharing`: Not shared by default, Shared, or Shared including
    passwords). A step up asks first, and an open session follows at once. A machine may have
    its own, which the options form and the toolbar's button set; Settings' doesn't override it,
    and every window to the machine follows it;
  - the Input mode each new window starts in (`AppSettings.inputMode`, stored and named through
    `CaptureMode+Labels`). A window keeps its own through reconnects, and the Input menu changes
    only that window's.
- **The sign-in's questions** (`SignInPrompter`, one per window, its `SignInQueue` the asker for
  the window's sessions, reconnects and Get Screens, the machine sheet's included): one question
  at a time as a sheet, on the machine sheet while that shows. A sheet is shown while Glifftop
  is active and the window isn't minimized, and kept shown after: AppKit would bring a window
  forward, over the app in front or out of the Dock, to attach one. Each names the host as typed
  (`SignInQuestion.hostShown`), and only an answer, or the question ending, dismisses one.
  - `HostKeySheet`: a key ssh doesn't know (its type and fingerprint, selectable, and how to
    check it) or ssh's yes/no question about one, with Deny (Escape) and Allow and no default.
  - `SecretSheet`: a passphrase, PIN or password, or the host's own question set apart under
    "HOST asks:", laid out as the Mac's sign-in sheets: a heading saying what it is for ("Sign
    in to HOST", "Unlock the key PATH"), a password's user on a row of its own, a labelled
    secure field (marked as a password for AutoFill, for a password or a key's passphrase),
    Continue and Cancel. The field is emptied as the answer goes.
  - A notice, such as a security key's touch, with no buttons, until ssh is done.
- **The Debug menu** (Debug builds): Protocol Inspector (⌥⌘I: `InspectorView`, a section per
  open window titled as its tab, with each message type's count, bytes, last seen and rate per
  direction, and the last 200 messages, refreshed once a second, with Pause and Clear;
  `InspectorModel` holds a `ProtocolTally` per window behind a `Mutex`, filled by the session's
  `ProtocolObserver`: types and sizes only, never a body), Record 5 Seconds, and Test Cursor
  Shape (`TestCursor`'s crosshair in place of the session's shapes).

- **Owns:**
  - `MachineStore`: the saved machines in `UserDefaults` (key `machines`), as GliffMachines'
    JSON.
  - `SessionModel`: one window's session, made and given the window's input in
    `SessionModel+Start.swift`, folded into a `SessionSnapshot`.
    - Its machine (`SessionModel+Machines.swift`): the destination's when it starts; recorded,
      with the window's options and the date, when it first streams, so a host that never
      streams isn't saved; View-menu changes of screen, text size, resolution and Scale to Fit
      kept on it.
    - The session's `PictureSlot` and the app's one `PictureRenderer`, the picture not shown
      while the session holds it (`SessionSnapshot.holdsPicture`: "Waiting for video" meanwhile,
      or a reconnect's last picture).
    - The window's sizing, set once per session: `.fillScreen` for a virtual screen (from the
      start), else `.monitor` from the first view within the monitor
      (`SessionSnapshot.mirrorSize`). The window's Scale to Fit, text size, resolution and
      reconnect come from the machine's options at each connection and are kept when the screen
      is switched. The video view's drawable and backing scale are passed on as the session's
      `ViewTarget`, with the window's live resize.
    - Switching the session to another screen, a new session to the same host
      (`SessionModel+Screens.swift`), the window staying in full screen meanwhile
      (`isSwitching`).
    - A lost session tried again with backoff (`SessionModel+Reconnect.swift`, GliffSession's
      `Reconnector`): a session that streamed and ended with a reason a retry may fix, Reconnect
      automatically on. Each try is a new session in the same window, its size and full screen
      kept. A Focused Monitor mirror's try (and its Try Again) asks for the monitor it last
      showed (GliffMachines' `ReconnectScreen`), its choice still Focused Monitor, and with that
      monitor missing the focused one at once, in the same try. Disconnect, closing the window,
      quitting, another connection or Reconnect automatically turned off stops it (the last,
      with why it was lost on the end screen).
    - `SessionEndedView` after an end the person didn't choose, with Try Again, Edit Machine…
      and Close; Disconnect and Cancel go straight back to the machines.
  - `AppConnections`: the app's one `HostConnections`, each session and Get Screens a channel on
    its host's one signed-in ssh, which asks its questions through the bundle's askpass helper;
    and its one `InputBarrier`, handed to every session, so another tab's input waits until a
    modifier release is answered by its server.
  - `AppPorts`: the app's one `PortsRegistry` on those connections, started at launch. It holds
    each open window's host while its session is active, with its machine's "Forward when
    connected" ports, following `OpenSessions` and each model's session and machine. Each window
    has a `PortsModel`, the host's latest snapshot and the actions on it. "Forward new ports
    automatically" is kept in `UserDefaults` and shown in Settings by `PortsSettingsSection` and
    in the popover. The machine sheet's `MachinePortsSection` holds its saved ports; its typed
    port takes Return from the sheet's Save, which keeps it (`PendingEntryKey`).
  - `ScreenList`: the host's monitors, listed through a lister closure, by default on the host's
    shared connection, and never saved. One listing at a time, stopped (its error dismissed)
    when a session starts; a refresh keeps the list until the new one arrives. The list belongs
    to its host and is forgotten when the field names another, and a monitor is chosen only from
    its own host's list.
  - The views, and the app's display text for GliffKit values, text sizes included
    (`DisplayNames.swift`; GliffKit carries no UI text). `ClipboardReadView` shows the host's
    read of the Mac clipboard in the toolbar and the status bar: while it runs (reported after a
    second) with the bytes sent and Cancel (`SessionModel.cancelClipboardServing`), and for 3 s
    after a failure with why.
- **Imports:** SwiftUI, Observation, Foundation, UniformTypeIdentifiers, Metal (the system GPU
  for the renderer), `os` and the GliffKit modules. Must not import AppKit: anything AppKit goes
  through `MacPlatform`.

## MacPlatform

AppKit adapters for what SwiftUI can't do:

- the attached displays' size in pixels (`DisplayMetrics`);
- whether a window's toolbar is on screen (`WindowToolbar`), and text put on the clipboard
  (`TextPasteboard`, Copy Address);
- committing what a field holds before a form reads it, text still being composed or put there
  by AutoFill (`TextComposition`: commits the composition in place, tells the input method, and
  returns the field's own value; the SwiftUI binding may update later);
- quitting that waits for the sessions' Bye (`AppDelegate`, which knows only a `beforeQuit`
  closure; `GlifftopApp` hands it `OpenSessions.shutdownAll`, then `AppConnections.closeAll`),
  and closing the last window quits;
- the ⌘Q guard (`QuitGuard`): while a session is live in some window (connecting, streaming,
  interrupted or reconnecting: `OpenSessions`' `guardsQuit`), a quit whose current event is a ⌘
  key-down (Quit's key equivalent, whatever the layout) is held back, `QuitHold` running on the
  events' own times. "Hold ⌘Q to Quit" shows at once in `QuitHoldPanel` (borderless,
  non-activating, click-through, floating, on the key window's screen, glass on its own content,
  announced to VoiceOver). ⌘ and the key held 1 s (key-ups end it; at the deadline
  `CGEventSource.keyState` and the modifier flags confirm it), or a fresh press while it shows,
  quits from the run loop; let go early, it stays 1.5 s, then fades. Quit from a menu or by an
  Apple event (the Dock, logout, restart, a script) isn't guarded;
- native tabs (`WindowTabbing`): a SwiftUI window is already ordered in when its content reaches
  it, so a new tab joins its group with `addTabbedWindow`, after the last tab. A window opened
  alone that macOS tabbed anyway leaves its group, as does a new window whose group has a sheet
  up on any tab (AppKit would lay the group out at the sheet's size). It reports the window's
  number, its group's in tab order (KVO on the group's windows) and the window's close. Close
  Window closes every tab of the key window's group. A window opened for Show All Monitors
  leaves its source key: its tab joins unselected; its own window is ordered behind at its
  `WindowPlace`, its cascade step from its display's visible top-left (`WindowPlacement`; a
  display gone leaves it where macOS put it), else from the source's top-left (its display's
  visible frame in full screen). The source is made key again, then and after SwiftUI's update,
  unless the person has moved to another window, quietly (`CaptureController.rekeyQuietly`: no
  activation's nudge, the host's focus never having left its screen);
- switching tabs (`TabSwitcher`): Window ▸ Previous Tab and Next Tab (⇧⌘[, ⇧⌘]), and the same
  chord over the picture, taken by `CaptureController`'s key monitor before the remote (while
  captured, too), select the window's previous or next tab; in a window of one tab, the previous
  or next session window in opening order (a group once, as its selected tab), whose Space comes
  forward;
- the video view: `VideoNSView`, a `CAMetalLayer` (sRGB, opaque) that a display link draws into
  through `PictureRenderer` only when there is a new picture, a new drawable size or a new view
  box for the picture on screen, or Scale to Fit toggled, and only while the window is visible;
  wrapped for SwiftUI by `VideoView`. Once the window has been fitted for the session it reports
  its drawable size and backing scale (`onTarget`) on every change, from the display link and as
  a live resize ends, never from the machines window. Its cursor handling is in
  `VideoNSView+Cursor.swift`, and where points fall on the picture in
  `VideoNSView+Mapping.swift`;
- `WakeObserver`: the Mac waking (`NSWorkspace.didWakeNotification`) and whether the network
  path is usable (`NWPathMonitor`), for the session's probe and its reconnect;
- `FullScreenTracker`: the window's full-screen state for `RootView`, which keeps its content
  resizable while full screen (fixed-size content makes the window ignore `toggleFullScreen`),
  and leaving full screen when the picture goes (not while View ▸ Screen or a lost session
  reconnects, nor while a virtual screen's session awaits its picture), so the compact end
  screen isn't a box on black;
- `WindowSizer`: for a mirror (`WindowSizing.monitor`), the window at 1:1 for the monitor when
  that fits the screen, else the largest fitting size (`VideoFit.contentSize`), when streaming
  starts and on View ▸ Actual Size, never for a later view (the server shrinks a mirror to the
  window); for a virtual screen (`.fillScreen`), the screen's visible area as the session starts
  (`SessionAreaTracker`), and again when its picture first shows. A full-screen window keeps its
  screen. A window with other tabs keeps the group's size: no session sizes it, a mirror draws
  fitted (`SessionModel.sharesWindow`), the machines stay resizable and Actual Size is off; a
  mirror left alone (torn off) is fitted again;
- `AttentionTracker`: a new sign-in question selects its window's tab and brings it forward
  while Glifftop is active and it isn't minimized, else bounces the Dock icon once
  (`requestUserAttention`); the window that bounced last comes forward, once, when Glifftop is
  next made active and it isn't minimized, and Glifftop's Dock icon counts the questions open in
  minimized windows; it tells `SignInPrompter.windowReady`;
- `LiveResizeTracker`: the window's live resize (a drag of its edge), for
  `SessionModel.liveResizeChanged`, which tells the session (no Resize during one) and any
  session started during one. It reports the end a turn after AppKit's, once the video view (or
  `SessionAreaTracker`) has laid out and reported the size it ended on, and when it leaves its
  window;
- `SessionAreaTracker`: a virtual screen's window before its picture, filled once and measured
  as the video view will be (`NSView.backingPixels`, less the status bar), so the remote screen
  is asked for that size while the session connects;
- input capture, keys and pointer together: `CaptureController` (one per window's session) feeds
  GliffInput's `InputController` the window, app, picture, link, popover, sleep and lock changes
  (its observers in `CaptureController+Observers.swift`), swallows the window's key events while
  captured (a local monitor, only while there is a picture), takes the pointer events
  `VideoNSView` hands it (`onPointer`), sends what it says through `Session.send`, and shows the
  mode's hint for 3 s. It holds the mode, Integrated or Capture, applied on change and to each
  session attached. An overlay holds capture off: any menu of the app open (`MenuTracker`) or
  the Ports popover; Input ▸ Release Input stays enabled through either. In Integrated, a key
  with ⌘ over the chrome (`ChromeProbe`) is the Mac's.
- activations: capture turning on (the window or tab coming to the front, the first picture,
  recapture), a wake, an unlock and a user switch back while captured. An overlay closing is one
  only if capture would have risen while it was open; a window the app makes key again itself
  (`rekeyQuietly`) is none, nor is an overlay's close after it. Before anything else an
  activation sends two motions onto `SessionModel.activationTarget` (`FocusTarget`: a handover's
  entry point, else `VideoNSView`'s Mac pointer over the uncovered picture, else the session's
  `RemotePointerSlot`, else the centre), so the host's focus follows to the tab's screen. They
  go through `Session.activate`, so a key typed at once after a switch waits for the host's
  focus. `CaptureTracker` tells the capture its window, whether the session's own picture shows
  (not a reconnect's last one) and whether the Ports popover is on screen. `InputSource` reads
  the selected layout (HIToolbox's TIS) as the keymap text, and whether the keyboard is ISO;
  `MacKeyEvent+NSEvent` and `PointerEvent+NSEvent` turn an `NSEvent` into values;
- the pointer handover between a host's monitor windows: `MonitorHandoverCoordinator` (app-wide)
  watches the picture of each live mirror whose window isn't key through a
  `PictureHoverWatcher`, a second tracking area on its video view (motion and exit while the app
  is active). Each capture tells it of its key changes, group and video view, and each video
  view of joining or leaving a window, so a window never key watches from its first picture. At
  each motion, while the key window can leave, it gathers both windows' facts
  (`CaptureController+Handover.swift`: the group the app sets from
  `SessionModel.sessionPhaseChanged`, the destination while the session streams a monitor; the
  mode; the picture live; released; captured; a sheet) and the pointer's (the app active, no
  button, over the picture drawn, that window frontmost there, asked of the window server only
  then) for GliffInput's `MonitorHandover`, and checks them again at its deadline. Handing over,
  the other window's capture keeps the last motion's remote position as its entry point
  (GliffInput's `HandoverEntry`, used once by that key change's activation, gone on any other or
  after 500 ms), and the window comes in front (`makeKeyAndOrderFront`, after the event that
  answered, whose watcher the key change removes), its activation nudging the host's pointer
  there instead of asking the window server;
- which window is on top at a point (`NSWindow.shownNumber`): the window server's answer, read
  through tab groups (`NSWindow.shownTab`, a group's selected tab). At a tab switch the server
  still names the tab just left for a frame or so; the tab now selected stands for it, so the
  activation finds the Mac pointer over the new tab's picture at once. The Mac pointer's place
  over the picture, `ChromeProbe` and confinement's start all ask it;
- `ChromeProbe`: where a key event happened, for Integrated's ⌘ chords. It reads the event's
  location (`ScreenCoordinates` flips Quartz's global coordinates into AppKit's), the window
  under it, the video view's frame on screen and the menu bar's strip, and lets GliffInput's
  `PointerPlace.classify` decide: the chrome is the session window's title bar, toolbar, tab bar
  and status bar, its popovers (child windows), and the menu bar;
- Capture mode's confined pointer (`CaptureController+Confinement.swift`): once GliffInput says
  it is confined (captured, and the pointer has entered the picture), `PointerConfinement` warps
  the hidden Mac cursor to the video view's centre, cuts it off from the mouse
  (`CGAssociateMouseAndMouseCursorPosition`) and takes every mouse event of the app through a
  local monitor. Each motion moves the virtual pointer by a remote delta at the absolute
  mapping's scale (`VideoNSView.remoteDelta`); buttons and scrolls land where it is. The start
  warp's displacement is taken out of the first motion within 0.25 s that carries it
  (`StartWarp`). It starts where an activation puts the remote pointer, shown or hidden as the
  host's is, but not where the centre is off every display or another window covers it. When it
  ends, the Mac pointer comes back over the virtual pointer's place, if the window is on screen
  on the active Space. Each display-link tick follows the picture's size (`resizeConfined`) and
  gives every `CursorPos` since the last (a nil one is a new picture) and the picture drawn to
  `InputController.followHost` (the host's own moves adopted, echoes ignored), through the
  session's `HostPointerFollower`. `ConfinedCursorLayer`, over the picture, draws the pointer
  where the virtual one is after each motion and tick, with `RemoteCursor`'s sprite: nothing
  while the host hides its pointer, or with no shape to show over a video that carries it. The
  picture's own cursor is hidden meanwhile;
- where the pointer is, for capture: from the video view (`onHover`: over the picture drawn, not
  its bars, at each motion, the tracking area's enter and exit, a click and a scroll; ignored
  while confined) and, at the window's key edge and the app's active edge, from its place before
  the edge; reported when it changes, or when anything else was applied since. Suspensions
  report it off the picture: another app activating (no holding until this one is active and in
  front again), the app about to resign (none until it resigns or is active again), another
  Space, the window moving or changing size or screen, full screen's transitions (no holding
  until each ends), a sheet, and a check on each display-link tick (`onTick`) that the app is
  active, the window key, on screen and on the active Space, with no sheet or modal window;
- `MenuTracker`: whether any of the app's menus is open (the menu bar's, a toolbar pull-down's,
  a context menu's), counting `NSMenu`'s tracking begins against its ends once for the app, with
  a debug log line of the count;
- the pointer: `VideoNSView` takes the mouse buttons, drags and scrolling over the picture, and
  motion from a tracking area while the window is key, only where this window is frontmost and
  its hit test finds the picture (not under an overlay or another window); a drag that began on
  the picture keeps sending, clamped to its edge. Each point goes in drawable pixels through
  `PointerMapper` with the fit the renderer draws with. A click that only brings the window
  forward isn't sent (no first mouse).
- the cursor: `RemoteCursor` makes what GliffInput's `CursorLook` chooses into an `NSCursor`
  (the remote's shape with a remote pixel the size of a picture pixel, or a hidden one), made
  again only for a new shape or size. `VideoNSView` shows it (always through `showCursor`) on
  entering the picture and on each move, a drag included (AppKit sends no `mouseEntered` during
  one), and under a resting pointer when capture, the session, the shape or its size on screen
  changes, once the window is key, the app active and no live resize is on. Off the picture,
  AppKit, the overlays and other windows set their own (`cursorUpdate` goes to `super`). When
  the pointer stops being the picture's (onto an overlay or off the view, the window or app
  losing focus, taken at `willResignActive`; the picture going; the view leaving its window,
  even mid-resize), the cursor is given back as the arrow, but only while it is still the one
  shown (GliffInput's `CursorClaim`); the arrow (shown when released, or set on giving back) is
  never claimed. Regaining focus, the cursor is checked again under a resting pointer, as after
  a live resize or a move to another window. Each view has its own hidden cursor, and
  `SessionModel` gives each session a new `CursorSlot`;
- the clipboard, Mac → remote (files aren't shared): `ClipboardController` (one per window's
  session) tells GliffClipboard's `ClipboardPolicy` when the session's window comes to the front
  or leaves it (the app active and the window key, from `ClipboardTracker`), when the
  pasteboard's `changeCount` moves (polled twice a second, in front or not) and when the
  clipboard's sharing changes, and carries out its offers and withdrawals through the session;
  it reads only the pasteboard's types. `PasteboardTypes` maps them to mime types (text, HTML,
  PNG or TIFF as `image/png`; a Finder copy only as its names in text) and finds password
  managers' concealed and transient marks: such a copy is offered only while it's Shared
  including passwords, and then with KDE's `x-kde-passwordManagerHint`, so the host's clipboard
  history skips it. A host's copy one window put on the Mac (`ClipboardOrigin` remembers which
  destination's) is never offered back to that destination by another window; another host's
  window offers it, host to host. `PasteboardSource` reads the data when the remote pastes, only
  from the copy the offer was made from, a TIFF converted to PNG with ImageIO, at most 32 MiB.
  `HostClipboards` is the app's one `HostClipboardLedger` (GliffClipboard): each controller
  registers its session with a fresh id and the destination as typed, and reports when it comes
  in front, its sharing, its offers and withdrawals, and the host copies it sees. A Mac copy
  another window's session to the host holds isn't offered again from the front; an offer
  supersedes the host's other sessions; one made within 30 ms after another window's empty offer
  to the host waits until then. When the holder's session ends (closed, Disconnect, a lost link,
  another screen) or turns sharing off, the copy goes to the host's other windows, the last in
  front first, until one offers it, under the settings in force then. ⇧⌘W tells it every tab of
  the group first, so the tabs don't hand it to each other, and a tab that stays open (a sheet
  up) takes part again; quitting hands nothing over.
- the clipboard, remote → Mac: the host's offers reach the same policy, which puts them on the
  Mac while the window is in front, or holds them until it is back if the Mac's clipboard hasn't
  moved since. `RemotePasteboard` writes one item with its text, HTML and PNG, each fetched only
  when a Mac app pastes it, a remote password marked concealed; files alone write nothing.
  `PasteProvider` fetches while it runs the event loop, so Glifftop keeps drawing and Cancel
  works, and returns no data once the session has ended, sharing is off or the app is quitting
  (`AppDelegate` cancels a running paste first), nor for a second paste while one runs.
  `PasteProgressPanel` floats over the app being pasted into after a second: what is coming, the
  bytes so far and Cancel, or why it failed.
- **Imports:** AppKit, Carbon (HIToolbox's input sources and keyboard type), Metal, QuartzCore,
  CoreGraphics, ImageIO and UniformTypeIdentifiers (TIFF to PNG), Foundation, `os`,
  Synchronization (`PasteProvider`'s outcome), Observation, the GliffKit modules, and SwiftUI
  only for `NSViewRepresentable` wrappers. Must not use AppShell's views; AppShell calls in,
  never the reverse.
