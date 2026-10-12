# Read-ACK lookahead absorption — October 12

**Private timing derivative: abstract proof and source-extracted leaf pass.
Full-cache, whole-core, synthesis and physical acceptance remain unproven.**
This is not yet an FPGA timing gain or a replacement for the active
[FP-HIGH-VALID timing run](../../fpga/FP_HIGH_VALID_COFACTOR.md).

The measured predecessor path traverses speculative next-read admission,
selected cache tags/reuse, read acknowledgement and the FPU enable. Under an
active read, `mc_lookup_next` can be true only when the exact saved read owner
`rd_match` is true. That owner already acknowledges a cacheable, unflushed,
unsnooped read. The selected-next lookup therefore need not gate the **ACK's**
alternative window/code terms. Their data and capture qualifiers still need
their original lookup exclusion and remain unchanged.

[`prepare_read_ack_absorption.py`](prepare_read_ack_absorption.py) accepts only
FP-HIGH-VALID L1 SHA-256
`a9a1c8c640f2f5781765ca2f27979a664c1914fb14e4b93c348877b39ad29fae`.
It introduces ACK-only reuse cofactors, uses the existing current-tag hit
instead of the selected-current/next hit, and changes only `c_read_ack`'s
window/shadow/code alternatives. The original general ACK, data muxes, actual
reuse signals, next-read request/commit/capture and all sequential logic remain
unchanged. Existing `c_read_ack === c_ack` read-owner assertions remain active.
There is no feature switch, added memory port, new register or cycle added.
The code-fill alternative still references its existing eligibility logic;
no claim that every indirect lookahead path is removed is made before timing.

## Closed evidence

Root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

- `read-ack-absorption-proof-r1`: native Z3 reports **UNSAT** for binary
  old/new ACK inequality and for lookahead-with-active-request lacking a saved
  owner. Five broken formulas produce **SAT**, with counterexamples retained:
  removed saved owner, cacheability, residency, flush, and stream override.
  This is an abstract combinational model, not extracted-RTL or reachability
  proof. Code/fill eligibility is a shared, unconstrained input under the actual
  cacheability guards.
- `read-ack-absorption-leaf-r1`: the actual source equations pass **216,384
  binary-input comparisons** in Icarus. Coverage includes **11,564** active-read
  lookaheads, **22,114** primary-window, **22,028** shadow and **1,454** code reuse
  cases. All four separately compiled mutations fail natively at an explicit
  mismatch: saved owner, current residency, cacheability, flush. Source drift
  and reapplication are rejected. No whole cache's internals are forced; this
  test extracts combinational equations with unconstrained leaf state. It does
  **not** prove arbitrary X/Z equivalence or sequential ownership.

Qualified private derivative SHA-256:
`297de63f0a65871549202aadc0228c4708f366cf0e34d0ce0c5ee7a14c2cab21`.

## Next gate

[`run_read_ack_absorption_cache.py`](run_read_ack_absorption_cache.py) reuses
the exact guarded full-size banked-cache miter, with all enabled responses,
data, tags, valid bits, LRU and state compared on both edges. It requires the
closed proof and leaf artifacts and rejects concurrent Vivado. It preserves
the 32-job build envelope and tests a native removed-read-owner mutation.
Only its preparation/CLI has been checked so far; it has **not run** yet.

After the current native timing audit closes, use its actual critical paths
to decide whether to advance this derivative. Require the full cache miter,
QEMU/parent whole-core state and cycles, canonical gates, matched PC/FPGA
transfer (including the separate DMA repair), CoreMark preflights, actual
>=40 MHz synthesized Fmax, routing and physical standard-suite acceptance.
No benchmark or timing exception is introduced to bypass that acceptance.

Current candidate gameplay IPC is unmeasured. Older verified simulation
baseline: **0.51030715 total U+V retirement events/cycle**, model `2b4d7a48`,
cycles **1,200,065,237–1,300,065,237**. It predates both timing derivatives.
