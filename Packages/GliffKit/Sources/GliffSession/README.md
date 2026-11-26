# GliffSession

Owns one Gliff protocol session: the handshake, the stream's rules, acks, recording, and
the feature seam.

- **Imports:** GliffProtocol, GliffTransport, GliffVideo, GliffInput, GliffClipboard, Foundation, `os` (Logger),
  `Synchronization`. Must not import AppKit, UIKit, SwiftUI or Observation.
- **`SessionCore`:** the rules as a pure struct (no I/O, clock or concurrency): server
  messages in, `SessionAction`s out. Ported from upstream's client (`net.rs`): Hello first;
  Ping answered with Pong in every state; HelloAck version 1 or the session is incompatible;
  anything but Ping, HelloAck, StreamConfig, Error, a clipboard message (or an unknown
  variant) before the first StreamConfig is a protocol error; a clipboard message before
  HelloAck is ignored; Error codes 1–255 are incompatible, 256 a setup failure.
  While streaming (`SessionCore+Streaming.swift`, `StreamRules`): StreamConfig checks,
  exactly one FrameAck per VideoFrame after decoding, the keyframe latch, RTT Pings, stats.
  A StreamConfig that changes the coded stream (size, chroma, codec, extradata) configures a
  new decoder; any other updates the kept one (`updateDecoder`: a new view box, pace, scale
  or pipeline).
- **`Session`:** the actor that runs a core against a `Transport` and a `FrameDecoder`: one
  reader, one writer task (`SessionWriter`), a 500 ms tick, and `status` as an
  `AsyncStream`. It reports `.interrupted(true)` when `Liveness` says so (a Ping unanswered
  for 2 s and not a byte for 4 s, on a clock that stops in sleep), and `.interrupted(false)`
  at the next bytes. `probe()` (after a wake or a network change, while streaming) sends a
  Ping at once and ends the session as `.connectionLost` unless that Ping's Pong (or a later
  Ping's, as upstream's writer may drop it), or any bytes 1 s or more after it, arrive within
  3 s; bytes sooner may predate the sleep, so they
  don't answer it. `withdrawProbe()` (the network went away) drops a probe waiting; the
  next probe decides. The handshake isn't probed. Closing waits up to 1 s for queued frames (Bye), then closes the
  connection, or abandons it (`ByteConnection.abandon()`) after an unanswered probe or when it ends while interrupted. Cancelling `run()` is a disconnect. A run of decode failures logs each
  reason once; the next picture ends the run.
- **Input:** `Session.send(_:)` queues an `InputMessage` from any thread (`InputQueue`, in
  order); the session sends what `InputGate` admits: a key or button press, motion and
  scrolling only while streaming and not interrupted; a release (or a scroll's stop) only if
  what it ends went, and then even while interrupted (so the remote never holds a key or
  button past a stall, nor gets an unpaired release); a keymap always.
  Anything queued before the handshake is judged then, held by the barrier or not (a press is
  dropped), on a copy of the gate (`InputGate.preview`), as delivery judges what stays.
  `disconnect()`
  sends the queue before Bye; after the end nothing is kept. While the transport is still
  connecting, `disconnect()` cancels that connect instead (`TransportError.cancelled`).
- **The barrier between sessions:** a session's input is in order within that session only;
  each session reaches the host by its own channel and `gliff-server`, and Hyprland can read
  one session's next key before another's modifier release. `InputBarrier` (one for the app,
  handed to each `Session`) keeps the last modifier key release (the eight evdev codes of
  `MacKeyTranslator.modifierCodes`), and another session's input waits until that release is
  answered:
  - The releasing session queues a fence behind the release (`Queued.fence`); once it has gone,
    the session sends a Ping (`Session+Barrier.swift`). Upstream's server handles a session's
    messages in order on one task and hands each input to its input thread before answering a
    Ping, so that Ping's Pong says the release has been handed on. Each Pong echoes its Ping's
    `t`, and each Ping's `t` is its own (`SessionCore.pingNow`). Upstream's writer drops a Pong
    still queued when a newer one is, so a Pong answers its own Ping and every one before it
    (`FenceLedger`). The stats' and a probe's Pings, answered first, answer nothing. A
    release sent while no Ping can go (no stream yet) waits for the next Ping.
  - The waiting session queues a hold in front of its input
    (`InputQueue.holdWhatFollows(for:awaiting:)`, `Queued.until`) that ends
    `InputBarrier.settle` (10 ms, for the server's input thread and the compositor) after the
    answer, or `InputBarrier.limit` (250 ms) after the release goes if none comes; the barrier
    tells the queue of the answer (`whenAnswered`), which wakes its timer. Reaching the limit
    is logged. A server busy encoding reads its input late, so no fixed time is enough.
  - What that session queued before the hold goes as it would: another session's wait counted
    on it, and holding it back would let that session's input overtake it, an activation's
    motions and keys included.

  A release that waits counts its limit from when it leaves its queue: after the barrier's
  wait and whatever is queued in front of it, each hold and activation pause in turn
  (`InputQueue.delay`). Sessions are told apart by an `InputBarrier.Sender` each, never
  reused. A hold or pause starts its timer once reached, one at a time. `disconnect()` sends a
  held queue anyway, before Bye.
  `InputBarrier`, `InputQueue` and `ReconnectMemory` time themselves with `Clock.stopwatch()`
  (`Stopwatch.swift`).
  - The barrier is app-wide: a tab to another host waits one round trip too, which no one
    sees.
  - At the session's end, its releases not yet answered are answered once its connection has
    closed (the server has handled its Bye), and those never sent at once.
  - A release held up longer than the limit (a stalled link) isn't covered. A release the gate
    drops is still answered.
- **Activation:** `Session.activate(_:)` queues an activation's motions
  (`InputController.activate(at:)`), then a pause (`Queued.pause`): input sent after
  them waits `Session.activationPause` (50 ms) from when they go, behind any barrier wait. The
  host's focus takes a moment to follow the motions, and a key that lands at once after them
  reaches neither the window left nor the one reached.
- **Resize:** `Session.setViewTarget(_:)` takes the window's size in pixels, its backing
  scale, text factor (`TextSize`) and resolution (`VirtualResolution`), as a `ViewTarget`,
  from any thread, latest wins; `Session.setLiveResize(_:)` the window's live resize, its
  starts and ends in order. `ResizeRules` sends a Resize while video is streaming: one due
  at the first StreamConfig goes with it, ahead of the decoder; the first one it can send at
  once; none during a live resize, and the size it ended on at once; any other once it has
  stayed unchanged for 200 ms (a wake just past the settle time, the tick as backup). No
  smaller than 320×240; a mirror's scale the backing scale (0.5–4), a virtual screen's the
  backing scale times the text factor (1–4); a virtual screen's size and scale then times
  its resolution's factor (½ for Standard on a Retina display whose window at ½ still fits
  320×240, or Automatic on a CPU pipeline; the layout stays the same, the scale perhaps
  down to 0.5); never the same
  request twice, nor one the StreamConfig in force already answers.
- **Held picture:** `PictureHold` keeps a virtual screen's first picture back
  (`.pictureHeld(true)`, just before the first `.streaming`) while the server's default
  screen (1920×1080 at 1) awaits the window's size: until the first picture decoded from a
  frame after a StreamConfig with another view, a size that leaves nothing to ask for, or 2 s
  after the first frame or a later Resize. A release in a StreamConfig's batch comes after
  its `.streaming`. A mirror is never held, nor a picture once shown.
- **Cursor:** a CursorShape while streaming is checked with its frame's payload
  (GliffInput's `CursorImage`, with the pixels it declares; bytes past them are skipped) and
  published to the `CursorSlot` the session was made with (latest wins, a generation per
  publish, like `PictureSlot`: a shape can be 4 MB). One that can't be shown is published as
  nil, so the arrow replaces the old shape (upstream `set_remote_cursor`), and logged once per
  session. A CursorPos is published to the session's `RemotePointerSlot` (capture-buffer
  pixels, which can exceed a shrunk stream's, and whether the host shows a pointer; one that
  isn't a number is dropped), cleared by a StreamConfig that brings a new picture and by the
  session's end. Each publish moves its generation (`read()`), so a poller sees a report at
  the same place, and the last `recentLimit` reports are kept (`reports(after:)`), so a poller
  sees each one since its last look. `HostPointerFollower` is one such reader for a confined
  pointer: `start()` is one look (the last report, where the host hid its pointer, whether a
  new picture is pending), as `InputController.confine` takes it; `reports()` is every report
  since the last look, as `InputController.followHost` takes them. A shape
  or a position before the first StreamConfig is a protocol error (upstream).
- **`SessionSnapshot`:** the statuses folded into what a window shows (phase, the server's
  session (headless or not), its own output from HelloAck (`output`; nil when HelloAck lists
  none, or its size is impossible, outside 1–16384 a side), `mirrorSize` (what a mirror's
  window is fitted to: the first view, which the server caps to its encoder, within the
  monitor), stream, last stats, end, and `holdsPicture` and `isInterrupted`, which the end
  clears); nothing after the end changes it.
- **Recording:** `StreamRecorder` writes the raw frames, wire-exact, to a `.gliffrec` file:
  the StreamConfig, then video frames from the first keyframe. Nothing else.
- **Protocol observer:** a session made with a `ProtocolObserver` tells it of each frame
  written (once written, by the writer) and read (once framed and decoded): its direction,
  message type, whole size and time, never its body or payload (`ProtocolEvent`).
  `ProtocolTally` folds the events into the Debug inspector's table: per direction and type,
  the count, bytes, last time and the last second's count, and the latest 200 events.
- **Ends:** `SessionEnd` says why a session ended, with the message the app shows and
  whether a reconnect may help (`mayReconnect`). Before HelloAck any failure is a failure to
  connect (a write error waits for ssh's classified exit); after it, a lost connection. A
  parse error on the very first frame means stdout wasn't Gliff (`remoteNotGliff`). Server
  text is made displayable as ssh's stderr is.
- **Reconnect:** `ReconnectPolicy` says whether an end is tried again and after how long: an
  end that may reconnect, and, once retrying, a host not found, a connection refused or a
  failure ssh doesn't classify (a network or host coming back after a wake); after 1, 2, 4, 8
  and 16 s, then it gives up. `Reconnector` runs it: a countdown before each try
  (`ReconnectState`, for the window), cut short by `reconnectNow()`, stopped while
  `networkAvailable(false)` without spending a try and started again once the network is back,
  and ended by cancelling its task (Disconnect).
  A run counts from the first try, unless the last run's session ended within `ReconnectMemory.steadyTime`
  (30 s) of streaming: then it goes on from that count (`ReconnectMemory`, shared by a
  window's reconnectors), so a host that streams, then drops, runs out of tries. Its clock (by default one that stops in sleep) is
  injected; tests use `ManualClock`.
- **Features:** `SessionFeature` is an optional protocol feature as a plug-in unit: offered
  in Hello by name, active once HelloAck echoes it, then handed the unknown server variants
  it claims. `FeatureContext` lets it send its own client messages.
- **Clipboard:** a session given a `ClipboardSetup` owns a `ClipboardBridge` (`clipboard`).
  Its messages go straight to the writer (`ClipboardWire`), `Data` chunks in a bulk lane that
  yields to other frames (but takes a turn after every 8) and is dropped at the drain.
  `offerClipboard` and `revokeClipboard` are queued with the input, in the order they
  happened: input before one goes first, input after it waits until it is carried out, and
  they wait for the writer. The app never calls the bridge's `offer` or `revoke` itself. The
  bridge's events arrive as `.clipboardOffer` and `.clipboardActivity`; it closes before the connection does,
  and a read still shown running then ends as failed.
