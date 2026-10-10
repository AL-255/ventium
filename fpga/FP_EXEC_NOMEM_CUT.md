# FP-only ACK dependency cut — 2026-10-10

Status: **private candidate; not 40 MHz, not a standard-suite or FPGA pass**.
The target remains at least 40 MHz synthesized Fmax with UV, system/relocated
fast pipeline and fast memory enabled, followed by routed and physical validation.
The preceding [L1 candidate](L1_LEGACY_CAPTURE_CUT.md) measured only **22.4916 MHz**
in unplaced diagnostic logic-only mapping. No timing exception is introduced.

## Why the first attempt was rejected

The actual mapped critical path traverses memory ACK / `pipe_mem_wait`, then
`fp_shared_direct`, and ends at the shared FPU bank enable. The V-response
capture paths also traverse that FP eligibility logic. An executable live x87
descriptor does not issue an integer load/store; an outstanding integer packet
must nevertheless exclude live FP execution.

Replacing `!pipe_mem_wait` in **`pipe_fp_live_arm` itself** was wrong. Despite
its name, that signal also permits integer address-dependency and reference
operand priming in `core_agi_resident_prime.svh` and
`core_ref_operand_prime.svh`. The broad replacement disabled these paths.

The rejected full-PC model `48ee44c0` passed CRCs but increased the short
CoreMark performance seed from **4,767,218 to 4,886,214 clocks: +2.496% clocks,
−2.435% throughput**. Its original full-core model was `14d3920a`.
Its focused FP tests missed the integer consumers; their passes are not overall
qualification. The old `prepare_fp_nomem_arm.py` recipe is retained only as
negative-control provenance, **not a recommended implementation**.

Evidence remains in external scratch `ventium-fp-nomem.anUKwu40`. Validation
seed execution was stopped by the failed performance check. Its attempted
synthesis controller failed a pathname precheck before launching Vivado; there
is no synthesis result for that rejected candidate. Original failures remain.

## Corrected implementation

[prepare_fp_nomem_exec.py](../verif/issue_uv/prepare_fp_nomem_exec.py) leaves the
shared `pipe_fp_live_arm` definition byte-for-byte unchanged. A separate
`pipe_fp_nomem_arm` preserves the state, frontend, ownership, stall and issue
guards, replacing only the irrelevant integer-memory ACK dependency with the
live decoder's non-integer-memory qualification. Only `pipe_fp_fast_exec_ok`
consumes it. Its consumers were checked recursively through the include files.
Fault/debug/trap checks, accepted edges, cache geometry and feature defines are
unchanged. Simulation assertions check the decoder and memory-wait invariants.

The private full-core binary is
`429fcf4dbb718a8b83da41fa4a3e28cd68b5328c0c2a7ba24fe377e66dc91c3a`;
changed `core.sv` SHA-256:
`93865328ee935db1f1bf0677fce39f6071af14f9ea4f98be44569c6d91a95f83`.
Root: `/home/yukidama/external/tmp/ventium-fp-exec-cut.MNkzxfBO`.
The parent is the source-qualified `de02d77f` L1 timing candidate, not the
rejected FP model or the unrelated dirty checkout.

## Regression evidence

- Four recipe tests require the exact two edits and reject source drift and
  reapplication.
- The actual-decoder/source-extracted leaf compares **4,653,056 samples per
  profile**, including hardware, strict-MF and legacy variants. It now also
  compares the shared permit on **integer** descriptors. All four deliberate
  owner/ACK/trap/shared-permit defects fail. Seven native runs close as expected.
- **72 cold paged FP/integer/memory cases**, six instruction offsets and both
  flat/relocated code, pass complete QEMU state checks at AXI latencies 0/7.
  Every candidate/control retirement state and cycle matches; actual pairing
  and early FP command acceptance are required, not inferred from defines.
- The TS/EM #NM fixture and five-case architectural-debug fixture pass native
  QEMU and complete A/B state/cycle checks. The deployed profile does not enable
  strict-MF; no whole-core strict-MF pass is claimed.
- [The new AGI regression](../verif/issue_uv/run_fp_nomem_agi.py) runs 12 cold
  flat/relocated address-dependency fixtures at AXI latencies 0/7. Corrected
  execution retains all **350 observed priming accepts**, identical states and
  clocks. The rejected model has **zero** accepts and fails all 12 complete
  cycle comparisons. This closes the specific coverage hole found by CoreMark.

The independent audit rechecks **6,687 pins**, **51,044 identical architectural
records and retirement cycles**, **7,268 early FP accepts** and **8,560 actual
V retirements** across the 86 cases. Audit SHA-256:
`cd12d757f2263ee988cd4627bac8b0adc24b5f44a990a92f043e49ad89ee2faa`.

The unchanged canonical differential gate closed with native make exit 2:
**7/108 functional passes**, and 12/19 scored cycle kernels outside their
bands, as on the parent. All 20 candidate/control complete cycle streams match.
No mask, golden or band changed; this is still **FAIL**, not a correctness pass.
Full-PC CoreMark and new synthesis remain pending.

## Resource handling and acceptance limits

Removed only 26 enumerated, rebuildable PCH files from completed builds,
recovering **2,185,261,056 allocated bytes**. `pch-prune-plan.json` and
`pch-prune-closed.json` retain exact paths, hashes/inodes and terminal build
owners. Binaries, sources, logs, traces and media are preserved.

Latest verified gameplay baseline: **0.51030715 total U+V retirement-event
IPC**, model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates
this candidate, which has no gameplay measurement, completed timedemo, Win95
acceptance, duration-valid CoreMark score or physical FPGA qualification.
