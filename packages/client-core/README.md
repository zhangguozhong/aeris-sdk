# aeris-client-core

The shared JavaScript ClientCore, PendingCall owner, protocol validation, diagnostics and flow control used by both the RN and Web adapters.

Version 0.25.0 preserves the 0.22.0 wire contract and callback lifecycle.

Import `ClientCore` and the protocol types from `aeris-client-core`. Supply an adapter implementing `connect`, `send`, and `close`, or use the RN/Web package factories.
