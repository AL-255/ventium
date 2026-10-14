# Fetch-fault page arithmetic — October 11, 2026

**Private arithmetic proposal, not integrated into the running synthesis or
queued descriptor build. No measured Fmax gain or whole-core qualification.**

The subsequently completed [exact-fragment report](FRAGMENT_READ_PAYLOAD.md)
measures 27.83654 MHz and has a different worst path: fast U/V decode through
read-ahead selection and paired-memory acceptance. **Defer this proposal**
until timing evidence identifies a relevant limiting path; it is not the next
full-chip timing candidate merely because its arithmetic tests pass.

The completed BUS netlist's 28.10410 MHz critical cone includes
`d_fetch_fault_len`, a full-width endpoint calculation, page comparison, and
`fetch_overlength_probe` before the shared translation/fragment/response path.
The V-response path alone has 123 logic levels and -10.174 ns setup slack.
This motivates shortening that arithmetic; it does not establish the next
candidate's bottleneck or predict Vivado's mapping.

[`prepare_fetch_fault_page.py`](../verif/issue_uv/prepare_fetch_fault_page.py)
is pinned to the prepared descriptor-width successor's `core.sv` SHA-256
`8ef0079de0a0f9eba1f48533f590e0908b96fbaea9ff64030183a5e3e0416ec0`.
It replaces two expressions, leaving the decoder, probe admission guards,
exception priority, requests, FSM and cycles unchanged.

The old page is `(flin + length - 1) & 0xfffff000`. Since length is five bits,
the result is on the current or an adjacent page. The candidate prepares
20-bit page+1 and page-1 in parallel; only a 13-bit offset+length sum depends
on the late decoded length. Sum=0 selects the preceding page, sum>4096 the
following page, and all other sums the current page. The same two flags
replace the final full-page inequality. Page numbers wrap at 20 bits, exactly
preserving 32-bit linear-address wrap. Zero length is retained too, without
assuming that the decoder can never produce it.

## Completed bounded checks

[`test_fetch_fault_page.py`](../verif/issue_uv/test_fetch_fault_page.py):

- Exact reversible two-expression source delta; drift and reapplication rejected.
- Z3 proves page-address and crossed-page identities over **all 32-bit
  addresses and all five-bit lengths**, including underflow and overflow.
- Missing-underflow, wrong-boundary and narrowed-carry mutants have formal
  counterexamples.
- Native Icarus executes the actual replacement SV over **1,048,576** input
  combinations: every offset and length on eight carry/wrap-sensitive pages.
  The candidate passes; wrong-boundary and missing-underflow variants fail
  with native exit 1.

The three tests close successfully in 2.64 seconds under a separate 1 GiB,
single-CPU bounded service; peak memory is 45,395,968 bytes. No competing
Verilator model build or Vivado family is launched. Owner:
`ventium-fetch-fault-page-leaf-oct11.service`, invocation
`fe1e07437cbc42c0b27be0baa23bf76a`, terminal native exit 0.

Evidence: `/home/yukidama/external/tmp/ventium-fetch-fault-page-leaf.h5av8nqd/`.
Evidence-list SHA-256:
`5c7f8f5a8fa005a8cc605e38299beabb0362a1a6ae1b3687577fad1982cd1eec`.
Its inputs were independently rehashed after closure. The unittest exit and
native solver/simulator results establish these checks; the evidence listing
alone is deliberately not a pass marker.

Adoption still requires the completed fragment timing report to justify this
next path, a private full-core derivative, original fetch-length/page-fault
differentials, canonical gates, the full standard suite and matched FPGA
synthesis/implementation. No timing exception or lower-frequency fallback is
introduced. The >=40 MHz synthesized-Fmax requirement remains open.

## October 14: limiting-path relevance returns

The closed [next-tag/FP-classifier timing audit](../verif/fp_compare/README.md)
now reports **32.405457079 MHz unplaced**. Its worst path again traverses
`d_fetch_fault_len`, `fetch_overlength_probe`, translation/cacheability and
paired-store/backing ACK before ESP writeback. That makes this already-proven
arithmetic proposal relevant to reconsider; it does **not** measure its gain.
The older hash guard deliberately rejects current `core.sv`
`6c020b3c171fb422756a7874fb48cd32a683953ff5b95d44b708be3a7fa08b1c`.
Do not bypass that guard or claim integration: rebase the exact two expressions
with a new source contract, rerun native arithmetic/fetch-fault tests and
whole-core differentials before any synthesis. The separate way-banked tag
proposal fixes a confirmed area-inference problem, not this entire critical path.

Latest verified gameplay baseline: **0.48176594 total U+V simulated IPC**,
older model `c7b95b78`, cycles **1,100,065,237–1,200,065,237**
([evidence](FP_REPAIR_EXPORT.md)). Current timing proposals have no gameplay
measurement, and no full timedemo or physical acceptance is implied.
