# GliffSFTP

SFTP version 3 packets (draft-ietf-secsh-filexfer-02), as OpenSSH's `sftp-server` speaks them:
pure encoding and decoding, no I/O.

## Owns

- The packet type numbers (`SFTPPacketType`).
- `SFTPFramer`: cuts the stream into packets (`SFTPPacket`), at most 256 KiB + 1 KiB each and
  at least a type and an id; until VERSION, any broken rule is `.textBeforeVersion` (a login
  shell's text).
- `SFTPReader` and `SFTPWriter`: big-endian integers and length-prefixed strings, kept as bytes.
- `SFTPRequest`: every request Glifftop sends, encoded (never SYMLINK), with `SFTPOpenFlags`.
- `SFTPReply`: every reply, decoded under the limits on host input: VERSION 3 with at most 64
  extensions of at most 4 KiB; a STATUS keeps its code only (`SFTPStatusCode`), never its text;
  a name or handle is at most 4 KiB; a NAME's count must fit its bytes (12 each at least); its
  `longname` is read past, never kept.
- `SFTPAttributes`: size, owner (read only), permissions with their `S_IFMT` type
  (`SFTPFileType`), times (`SFTPTimes`); extended pairs read and skipped; a flag outside
  `0x8000000F` throws. Written attributes never carry an owner.
- `SFTPExtensions`: the OpenSSH extensions used (`posix-rename`, `statvfs`, `fsync`, `limits`),
  and their replies (`SFTPSpace`, `SFTPLimits`).
- `SFTPError`: each broken rule, which ends the session.

## Must not import

Anything: not Foundation, not another GliffKit module. Bytes are `[UInt8]` in and out, and
strings stay bytes (never decoded here). It builds for iOS.
