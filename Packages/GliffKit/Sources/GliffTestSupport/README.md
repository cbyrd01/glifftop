# GliffTestSupport

Test doubles that more than one test target uses. Only test targets depend on it, and it is not
part of the `GliffKit` product.

- `ManualClock`: a `Clock` that moves only when a test advances it, so a test's timing never
  depends on how busy the machine is.
- `onThread`: runs blocking work (a socket's `accept` or `read`) on a thread of its own, never
  on the cooperative pool, where blocked calls can take every thread and hang the test run.
- `value(within:_:)` and `within(_:_:)` poll for a value or a condition until a limit passes;
  `isGone(_:)` says a process has exited and been reaped.

It imports only the standard library, Foundation and `Synchronization`, and never a GliffKit
module.
