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
  (`message(host:)`). A STATUS keeps its code only: the host's text is never shown. A failure
  on this Mac (`local`, from its `errno` or a Foundation error's POSIX code) names this Mac
  instead, in the host's wording where the host has the same kind.
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
  so a path holding a newline stays whole; the parser (16 KiB, absolute paths only) drops an
  `xdg-user-dir` answer equal to home (a folder not set) and picks the fallback.
- `LocalFiles`: the Mac's side, through POSIX calls that never follow a link. Only a regular
  file is opened for reading (`lstat` before, `fstat` after; a FIFO isn't waited on, a tty
  never becomes the app's terminal); a temporary, `.<stem>.glifftop-<8 hex>`
  within 255 bytes, is made with `O_EXCL`, mode 0600 (a folder 0700), and moved in under its
  name never over an existing item unless asked (on a volume without `RENAME_EXCL`, checked
  first). `FileMetadata`: a mode is masked to 0o755
  with the owner's bits added; a time is clamped to SFTP v3's 32 bits.
- `Quarantine` (macOS): marks a download as a browser does, with agent Glifftop and no origin.
- `TemporaryLedger`: every temporary name, on this Mac or a host, recorded before it is made
  and forgotten once renamed in or removed, so leftovers are removed by exact name, never by a
  pattern, and only a batch's top-level temporaries are recorded. Leftovers are what was
  recorded before this launch (a running batch's are its own); one whose folder is missing,
  on a volume not mounted now, is kept for a later launch. A name that can't be
  recorded isn't made. `FileLedgerStore` keeps it as a JSON file written atomically before a
  name is made (it survives a quit or crash, not a power loss), skipping an entry it can't
  read.
- The module's logger: counts, byte totals, kinds and outcomes only; never a file name, a path,
  a single item's size, host text or a socket path.

## May import

Foundation, `os`, `Synchronization`, GliffSFTP and GliffTransport. POSIX calls come through
Foundation's re-export of Darwin.

## Must not import

GliffPorts, GliffSession, GliffVideo, GliffInput, GliffClipboard, AppKit, UIKit or SwiftUI. It
builds for iOS.
