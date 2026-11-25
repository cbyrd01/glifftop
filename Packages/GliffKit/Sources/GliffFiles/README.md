# GliffFiles

The sftp client: a session over any byte stream, transfers both ways, the Mac's own files, and
the quarantine on what it downloads.

## Owns

- The name of the ssh subsystem it speaks to (`SFTPSubsystem`).
- The module's logger: counts, byte totals, kinds and outcomes only; never a file name, a path,
  a single item's size, host text or a socket path.

## May import

Foundation, `os`, `Synchronization`, GliffSFTP and GliffTransport. POSIX calls come through
Foundation's re-export of Darwin.

## Must not import

GliffPorts, GliffSession, GliffVideo, GliffInput, GliffClipboard, AppKit, UIKit or SwiftUI. It
builds for iOS; only the quarantine is macOS-only (`#if os(macOS)`).
