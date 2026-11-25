# GliffFiles

The sftp client: a session over any byte stream.

## Owns

- The name of the ssh subsystem it speaks to (`SFTPSubsystem`).
- `SFTPSession`: one sftp conversation over any `ByteConnection`. INIT goes alone and VERSION
  must answer within 60 s; then one typed call per request, replies matched by id in any order.
  A cancelled caller's id stays outstanding and its reply is dropped when it comes; a reply to
  an id never issued or already answered, or of the wrong shape for its request (the wrong
  kind, STATUS OK where a value is due, empty DATA or NAME, DATA longer than asked), ends the
  session as broken. sftp-server answers in order, so any reply is progress: while a written
  request is outstanding, the next reply is due within the longest limit among them (60 s;
  fsync: plus 1 s per 16 MiB written), counted from the last reply or from the write that
  found none outstanding; with none in time, the session ends. An ending
  closes the stream, never the shared connection: a file server held up by a hung mount looks
  like a dead link, and ssh's keepalive finds a real one.
- `FilesError`: why an operation failed, with one sentence in Glifftop's words naming the host
  (`message(host:)`). A STATUS keeps its code only: the host's text is never shown.
- The module's logger: counts, byte totals, kinds and outcomes only; never a file name, a path,
  a single item's size, host text or a socket path.

## May import

Foundation, `os`, `Synchronization`, GliffSFTP and GliffTransport. POSIX calls come through
Foundation's re-export of Darwin.

## Must not import

GliffPorts, GliffSession, GliffVideo, GliffInput, GliffClipboard, AppKit, UIKit or SwiftUI. It
builds for iOS.
