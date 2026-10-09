# Same-edge admitted-store handoff

Experimental successor to [empty-buffer dispatch](WBUF_EMPTY_DISPATCH.md).
`prepare_wbuf_admit_dispatch.py` emits default-off
`VEN_P54_WBUF_ADMIT_DISPATCH`. It has **not** been promoted into a full-PC
acceptance build or deployed. Production defaults are unchanged.

A newly accepted store may enter the existing registered AXI launch state
when that state is empty or its old final beat handshakes on this edge.
Every older retained slot must have fully issued, or finish issuing now;
an older queued/unissued payload always wins. The new owner uses its normal
P54 ring slot. Both old response accounting and the two-entry bound remain
unchanged. Final-beat cleanup must not clear the new owner's `wr_active`.
The payload is selected **before** one shared byte-lane aligner, avoiding two
parallel variable shifters. Nothing bypasses read ordering or returns an
architectural store ACK without normal write-buffer admission.

## Closed evidence (2026-10-09)

`external/tmp/ventium-wbuf-admit.D1XyDU1j` contains frozen sources and recipes.

- `r2/closed.json`: 39 profiles/123 runs, including three expected old-latency
  failures and 120 positive results, with all six structural classes fatal.
  Reuses the empty-buffer capacity, ordering, byte-mask/split, fused/nonfused
  pair, reused-slot, foreign-ID, orphan-B and response-error corpus. The byte
  fixture additionally asserts next-clock AW/W ownership on same-edge handoff
  and requires real handoff witnesses under independent channel backpressure.
- `handoff-negative/closed.json`: three randomized-reset runs of the actual
  **empty-only** master fail specifically at the new handoff-latency assertion,
  not at the old empty-queue assertion, timeout or an unrelated error.
- `r1` is a retained failed fixture revision: it incorrectly required the new
  handoff witness in the disabled control, which cannot produce it. `r2`
  requires that witness only for the candidate. Original runner/recipe copies
  are retained. No RTL correctness failure is erased or relabelled.
- Two additional recipe unit tests pass (six including the empty recipe).
- Full-core **`c52fb423`** preserves the parent core/FP/L1 RTL and all original
  defines, changing only the AXI master and adding its opt-in define. Its
  same-input parent replay matches all108 complete architectural traces.
  Unmodified `make verify` still fails the existing101 terminal-length and
  four timing-band checks; parity is not a differential-gate pass.

Ten-iteration CoreMark results, both seeds/all five CRCs and no faults:

| Seed | Original `d2a117e7` | Empty-only `f75ccf1d` | Handoff `c52fb423` |
|---|---:|---:|---:|
| Performance AXI clocks | 5,264,309 | 5,245,654 | 5,241,779 |
| Validation AXI clocks | 5,257,586 | 5,239,192 | 5,235,258 |

Same 3,661,024/3,656,168 retirements, unchanged direct controls and same
cache-miss counts. Total improvement is only about**0.43%**; the extension
contributes about0.07% over empty-only. The ready byte fixture improves
536→518→452 clocks; blocked mode2443→2311→2311. Do not project that micro
speedup onto a workload. These short runs are **not valid CoreMark scores**.

## Isolated physical cost

`external/tmp/ventium-wbuf-admit-physical.8bgia22v`: original/off are identical
at493CLB LUTs/467registers. Enabled uses**654CLB LUTs/467registers** (+161LUTs,
no added state). Isolated setup estimate**359.71→301.84MHz**, not CPU Fmax.
All profiles still fail isolated hold at−0.080ns, so no timing sign-off.
One exclusive8GiB/no-swap Vivado family, native exit0,320.64seconds,3.62GB
observed peak cgroup RAM, no OOM/swap, stable pins and all vendor processes
gone. No processor bitstream or board programming.

Compared with empty-only, the shared-aligner version reduces LUT **primitive**
count826→733 and shortens the isolated setup path, but packed CLB LUT usage
**increases628→654**. Do not claim an FPGA area reduction from primitive counts
or attribute the combined change's packing difference solely to its shifter.

Latest verified gameplay is **0.44183623 total U+V IPC**, `652de481`, clocks
**1,200,000,000–1,300,000,000**. It predates both dispatch prototypes; neither
has gameplay or standard-suite acceptance. ≥0.48 remains open. The older full
direct-memory CoreMark scores2.107861982/2.110913372 (`cb4b2f84`) do not qualify
current cache/DDR throughput. Current-build full-seed host qualification is
separate and must preserve every guest clock.
