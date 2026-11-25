# GliffTestSupport

Test doubles that more than one test target uses. Only test targets depend on it, and it is not
part of the `GliffKit` product.

- `ManualClock`: a `Clock` that moves only when a test advances it, so a test's timing never
  depends on how busy the machine is.
- `SFTPBytes`: sftp packets built by hand, byte by byte, as an oracle for the codec and a
  script for a fake sftp server.
- `eventually`: waits up to 10 s of real time for a condition, a bound only a broken test
  reaches.
- `onThread`: runs blocking work (a socket's `accept` or `read`) on a thread of its own, never
  on the cooperative pool, where blocked calls can take every thread and hang the test run.

It imports only the standard library, Foundation and `Synchronization`, and never a GliffKit
module.
