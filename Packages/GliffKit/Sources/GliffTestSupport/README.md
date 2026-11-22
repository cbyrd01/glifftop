# GliffTestSupport

Test doubles that more than one test target uses. Only test targets depend on it, and it is not
part of the `GliffKit` product.

- `ManualClock`: a `Clock` that moves only when a test advances it, so a test's timing never
  depends on how busy the machine is.

It imports only the standard library and `Synchronization`, and never a GliffKit module.
