# GliffClipboard

Owns the clipboard's rules and transfers, platform-neutral: what may be offered, the checks on
what the remote offers, chunked transfers with flow control, and when the Mac's clipboard is
offered, revoked or replaced. It never touches a pasteboard: the app's MacPlatform carries out
what it decides. Files aren't shared: a remote offer's file list is ignored and a
file request refused; GliffProtocol still reads and writes both.

- **Imports:** GliffProtocol, Foundation, `os` (Logger), `Synchronization`. Must not import
  AppKit, UIKit, SwiftUI, GliffVideo, GliffTransport, GliffInput or GliffSession.
- **Privacy:** never logs clipboard contents, the remote's mime types, or the file names or
  paths of the lists it ignores; counts and byte totals only.
- **`ClipboardLimits`:** upstream's limits, exact (a chunk over 256 KiB ends the server's
  session).
- **`ClipboardMimes`:** upstream's mime rules: the five text flavours, the types worth offering
  (`forwardable`), the type that answers a request (`resolve`), and KDE's password hint.
- **`SendWindow`, `Assembler`, `ChunkError`:** flow control (four chunks in flight) and the
  receiver's check of order, size and cap.
- **`ChunkSource`, `ChunkSink`:** a transfer's two ends; `MemorySource` and `MemorySink`
  (capped).
- **`TransferProgress`:** the bytes moved so far (no total: no type's size is declared), polled
  by whatever shows progress.
- **`ClipboardTransfers`:** the transfers both ways (a port of upstream's `Transfers`): our
  requests take odd ids, a peer request with an odd id is refused; a fetch acks each chunk but
  the last and fails on a bad chunk, a peer `Abort`, cancellation (sending `Abort`), 30 s of
  silence or the connection's end; a serve sends at most four chunks ahead of the acks, then an
  empty final one (a source's over-long read is split). `receive` never waits on a sink or a
  source, and each sink or source call runs off the actor within the idle timeout
  (`withDeadline`), so a hung one cannot pin a transfer. `TransferError.message` is the
  plain sentence a person sees.
- **`ClipboardBridge`:** the client's clipboard over one session's transfers.
  - Mac → remote: `offer` (a fresh serial each time; a password manager's copy carries KDE's
    `x-kde-passwordManagerHint`, whose request gets one empty final chunk) and `revoke` (an
    empty offer only when asked). A request is served whenever it comes, only for the current
    offer and a type it holds. A file request is refused. The app's
    `LocalClipboardSource` reads the type in a task of its own, within the idle timeout; an
    offer, revoke or cancel stops reads still under way. Offers reach the wire in serial order. The host's reads of an offer are reported as one `ClipboardActivity`,
    after 1 s.
  - Remote → Mac: the remote's offer (its file list dropped) and `fetch` of a type into memory
    (32 MiB at most).
- **`ClipboardSharing`:** Share the clipboard, one setting of three (Not shared, Shared,
  Shared including passwords), in order of what each sends; Settings holds one, and a machine
  may hold its own.
- **`ClipboardPolicy`:** when to offer, withdraw, or put the remote's offer on the Mac,
  as a pure struct whose actions the app carries out. A Mac copy may be offered if it has types to
  forward, a password manager's only while passwords are shared, and never one this host's
  own session put on the Mac (another host's is offered, as a Mac copy) (`offerable`); a `recheck`
  when that changes withdraws our offer the clipboard no longer allows, in front or not, and
  in front offers one it now allows (never over a newer host copy).
