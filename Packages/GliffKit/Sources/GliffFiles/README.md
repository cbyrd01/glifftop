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
- `RemoteName` and `RemotePath`: a host's names and absolute paths as raw bytes. A name is
  never empty, `.`, `..`, or holds `/` or NUL or more than 255 bytes; a path is joined only
  from such names, so it never holds `..`. `shown` turns C0 controls and DEL into pictures
  and the rest of GliffTransport's `HostText.isHidden` (bidi, zero-width and tag characters,
  line breaks) into U+FFFD; `localName` is the shown form when it is a usable Mac name; an
  uploaded name is NFC.
- `RemoteListing`: a host folder's items (`RemoteEntry`: kind, size, time), with unusable or
  repeated names counted, hidden names kept for a view to show or not, and the listing stopped
  at 100,000 items (`.` and `..` aside) or 16 MiB of names from the host. Reading sends no
  STAT, so the listing comes back first; `lookUpLinks` then finds the target kind of at most
  256 links, leaving a refused one unknown and throwing any other failure (a STAT stuck in a
  hung mount holds sftp-server up until the session's time limit ends it).
- `HostFoldersCommand`: the one-line `sh` script that names the host's home (first),
  Downloads, Desktop and Documents (`xdg-user-dir` when set, falling back to
  `$HOME/Downloads`, then `$HOME`). The script prints what it finds, each record ended by NUL
  so a path holding a newline stays whole; the parser (16 KiB, absolute paths only) drops an `xdg-user-dir` answer equal to home (a folder not set) and
  picks the fallback.
- The module's logger: counts, byte totals, kinds and outcomes only; never a file name, a path,
  a single item's size, host text or a socket path.

## May import

Foundation, `os`, `Synchronization`, GliffSFTP and GliffTransport. POSIX calls come through
Foundation's re-export of Darwin.

## Must not import

GliffPorts, GliffSession, GliffVideo, GliffInput, GliffClipboard, AppKit, UIKit or SwiftUI. It
builds for iOS.
