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
  at 100,000 items (`.` and `..` aside; fewer when the caller asks, as a plan does) or 16 MiB
  of names from the host. Reading sends no
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
  pattern, and only a batch's top-level temporaries are recorded. This Mac's leftovers are
  what was recorded before this launch (a running batch's are its own); a host's are all its
  entries outside a running try, as its batches run one at a time. A local one whose folder is missing,
  on a volume not mounted now, is kept for a later launch. A name that can't be
  recorded isn't made. `FileLedgerStore` keeps it as a JSON file written atomically before a
  name is made (it survives a quit or crash, not a power loss), skipping an entry it can't
  read.
- `TransferPlan` (`UploadPlan`, `DownloadPlan`): what a batch copies, found before any byte
  moves, through `lstat` or LSTAT and listings: regular files and folders only, each folder
  before what it holds, sizes summed saturating. Links inside a folder, devices, FIFOs,
  sockets and host items without permissions are skipped and counted, as are host names with
  no usable Mac form; a link at the top level is followed (on the host, to where REALPATH
  says it leads) and its target must be a file or folder, and one that leads nowhere is
  skipped. More than 64 folders deep or 100,000 entries, skipped ones included, fails the
  plan (`tooLarge`); a cancelled caller stops it (`cancelled`). An unreadable folder fails it.
- `NameClash`: Finder's " 2", " 3" before the last extension, at most 1,000 tries, within
  255 bytes; `caseFolded` is the form under which this Mac takes two names as one.
- `NameClashPolicy`: how a batch settles a taken name: Finder's " 2" without asking, or a
  question (Replace, Keep Both, Stop, with "apply to all"); Replace only for a file over a
  file, on a server with `posix-rename`.
- `Pipeline`: a host's flow of reads and writes: 32 KiB blocks (or the server's smaller
  limit), at most 64 in flight across a batch, or 8 while the host streams; a new window
  applies at the next request. A download's reads stop at its planned size and one more there
  confirms the end, a short read re-asked at its offset; a file that ends early, or still goes
  on 1 MiB past its size, fails as changed.
- `TransferSettings`: what the server allows a batch (block size, files at once, `fsync`),
  read once per batch.
- `Upload`: a batch from this Mac to the host under `.<name>.glifftop-<8 hex>` names, opened
  with their final permissions, renamed in when whole (plain RENAME, so a name taken meanwhile
  is never overwritten; Replace is `posix-rename`). A folder is filled under real names, up
  to 8 files at once, and the first failure stops the rest. Every temporary is in the ledger
  before it is made; a failure or cancel removes it by name once it was made.
- `Download`: a batch from the host to this Mac under such names, made with `O_EXCL` and never
  over anything, each item quarantined and given its final permissions and time, then moved
  in with `RENAME_EXCL` or as "name 2". Inside a folder, a name this Mac takes as one already
  there gets " 2" and is counted. A host item that is no longer a regular file (LSTAT before
  OPEN, which follows links and waits on a FIFO; FSTAT after) is skipped and counted. The
  volume's free space is checked first; a failure or cancel removes the temporary with what it
  holds. A download never asks about a name.
- `FolderFill`: how either way fills a folder: items in the plan's order, files up to 8 at
  once (within the server's open-handle limit), the first failure or a cancel stopping the
  rest.
- `TransferProgress`: a batch's state (queued, running, finished, failed, cancelled) and its
  try's counts (items and bytes done of total, top-level items done, files skipped as special
  at open, items renamed inside a download's folder) and rate since the try began, polled.
- `HostFiles`, one per host (`FilesRegistry`, by the host as typed): the host's one sftp
  channel (`FilesChannels`: a `.subsystem("sftp")` channel on the shared connection), which
  serves browsing and transfers.
  - Its users are the Files window while open and each queued or running batch. It opens at
    the first user's first request and closes when the last leaves.
  - Callers waiting for it share one opening. A cancelled caller stops waiting at once; the
    last to go cancels the opening, and the next request opens afresh.
  - An opening's sign-in questions go to the oldest user with an asker when each is asked.
  - The first session reads the host's folders, or takes where sftp-server starts as home and
    Downloads. A command that hasn't ended within 15 s counts as failed.
  - A session opened with no try running removes the host's leftovers by exact name
    (`RemoteLeftovers`). A folder, when LSTAT still finds a real directory, goes with what it
    holds; anything else gets REMOVE, so no link is followed.
  - Its pipeline narrows to 8 while a session window to the host streams.
- The queue (`HostFiles+Queue`, `TransferBatch`): one batch at a time, in order, browsing
  between its requests.
  - Each try first removes the host's leftovers, then starts over the top-level items not
    finished. Dismiss removes them when connected with no try running.
  - Try Again takes the window that tries again: its asker, and, for an upload that asks about
    taken names, its asking.
  - `TransferActivity` (`ProcessInfo`'s, user-initiated with idle sleep held off) is held
    while a batch is queued or running.
- The module's logger: counts, byte totals, kinds and outcomes only; never a file name, a path,
  a single item's size, host text or a socket path.

## May import

Foundation, `os`, `Synchronization`, GliffSFTP and GliffTransport. POSIX calls come through
Foundation's re-export of Darwin.

## Must not import

GliffPorts, GliffSession, GliffVideo, GliffInput, GliffClipboard, AppKit, UIKit or SwiftUI. It
builds for iOS.
