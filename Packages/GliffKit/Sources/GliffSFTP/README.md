# GliffSFTP

SFTP version 3 packets (draft-ietf-secsh-filexfer-02), as OpenSSH's `sftp-server` speaks them:
pure encoding and decoding, no I/O.

## Owns

- The packet type numbers (`SFTPPacketType`).

## Must not import

Anything: not Foundation, not another GliffKit module. Bytes are `[UInt8]` in and out, and
strings stay bytes (never decoded here). It builds for iOS.
