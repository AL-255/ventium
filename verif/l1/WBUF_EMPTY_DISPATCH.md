# Registered empty write-buffer dispatch

Opt-in prototype, **not standard-suite or FPGA-deployment acceptance**.
`prepare_wbuf_empty_dispatch.py` derives a frozen master with
`VEN_P54_WBUF_EMPTY_DISPATCH`; the checkout's production default is unchanged.

When both P54 slots and the AXI launch registers are empty, the ordinary
accepted-store edge captures the checked payload into both its existing slot
and the existing registered AW/W launch state. Previously that launch capture
waited another clock. There is no combinational AXI VALID, new queue entry,
early B retirement, read bypass, guest predicate or relaxed error handling.
The store occupies its architectural slot until its final response. Both
unaligned split stores and fused U/V quadword payloads keep their old format.
Nonempty queue dispatch is unchanged.

## Evidence (2026-10-09)

Scratch root: `external/tmp/ventium-wbuf-empty.WZabgQpi`.

- `r2/closed.json`: **39 profiles / 123 runs**, with three expected negative
  outcomes reproducing the old extra-clock bubble. All 120 positive runs pass.
  Tests retain exactly two slots, read-after-write draining, independent AW/W
  backpressure, both reused ring slots, fused/nonfused pairs, error responses,
  foreign IDs and orphan B containment. A byte oracle covers all offsets and
  all 16 strobe masks, including split stores, poisoned live producer fields
  after ACK and ordered backing reads. Six structural warning classes are hard
  errors. Four recipe unit tests pass.
- `r1` is a retained **failed fixture attempt**: its ID/orphan tests used the
  wrong environmental-fault macro and triggered the assertions for the
  intentionally injected violation, on both control and candidate. `r2` uses
  precisely each existing gate's fault-injection macro; healthy tests retain
  normal assertions. The original runner is preserved in `r1/runner-source.py`.
- Full-core model **`f75ccf1d`** differs from `d2a117e7` in this master and its
  added define only. Frozen inputs, private harness basename/header and native
  build exit pass. UV, system-relocated fast pipeline and fast memory paths stay
  enabled; P5 cache geometry and integer execution occupancies stay unchanged.
- Ten-iteration CoreMark diagnostics, both seeds/all five CRCs, no faults:

  | Seed | Parent AXI clocks | Candidate AXI clocks | Clocks saved |
  |---|---:|---:|---:|
  | Performance | 5,264,309 | 5,245,654 | 18,655 (0.3544%) |
  | Validation | 5,257,586 | 5,239,192 | 18,394 (0.3499%) |

  Retirements stay 3,661,024 / 3,656,168. Direct-memory controls are unchanged
  at 4,821,818 / 4,815,105 clocks. These short runs **are not valid CM/MHz
  scores**. Performance-seed pipeline store waits fall 126,189→108,433 clocks.
  This is a small improvement, not closure of the ≥2.1 CM/MHz target.
- Unmodified `make verify` remains **FAIL**: 101 terminal-length mismatches
  and four cycle-band failures, as on the parent. Exact same-input parent
  replay matches all **108 architectural traces**, including their terminal
  records. This parity does not turn the mandatory gate into a pass or qualify
  the newly exposed terminal x87 comparisons against the newer observer.

## Remaining store-wait attribution

`prepare_wbuf_stall_profile.py` adds simulation-only counters beside the
actual master/L1 predicates. `SYNTHESIS` excludes them completely. Observation
model **`2527ec8f`**, `external/tmp/ventium-wbuf-profile.zRZvNT6P`, repeats all
four CoreMark diagnostics with identical clocks, retirements, CRCs, exclusive
FSM/pipe residency and pairing counts (`observation-audit.json`).

In the performance seed, L1 stores wait 1,097 clocks behind fills and 108,389
at the backing seam. The master counts 108,430 full-two-slot waits: 48,322 with
the oldest W channel blocked, and 60,108 awaiting dispatch/final issue. It
counts **zero** waits for an already-issued head's delayed B, zero AW-blocked
head waits, and no fault/shutdown/read-FSM blocking. These scopes differ
(slow/paired/backing producer boundaries), so do not subtract or add them as
one disjoint core-cycle budget. The head subdivision exactly sums to the
master's full-slot wait counter.

This standalone AXI slave accepts AW then W in separate states even at
`AXI_WLAT=0`; that is the tested backend, **not a measurement of FPGA DDR
latency**. The platform bridge's write-through profile can accept them
together. Do not change the slave timing merely to advertise a higher CPU
score, or classify these full-buffer waits as cache misses.

The isolated old/off/on master physical check closed at
`external/tmp/ventium-wbuf-empty-physical.91sse8x3`. Original and disabled
candidate are identical: **493 CLB LUTs / 467 registers**. Enabled uses
**628 CLB LUTs / 467 registers** (+135 LUTs, no extra state); LUT primitive
counts are a different metric, 647→826. Isolated setup estimates are
**359.71→240.10 MHz**, not CPU Fmax. All three fail isolated hold at −0.080ns,
so this is not timing sign-off. The small performance gain must be weighed
against the added selection/byte-alignment path before promotion.

One bounded Vivado family, native exit0, 264.68 seconds, 3.89GB observed peak
cgroup RAM, zero OOM/swap, stable source pins and no surviving vendor process.
No processor bitstream or programming was performed.

Latest verified gameplay remains **0.44183623 total U+V IPC**, model
`652de481`, clocks **1,200,000,000–1,300,000,000**. It predates this prototype;
the candidate has no gameplay IPC or completed standard suite. ≥0.48 remains
open. Full accepted direct-memory CoreMark remains 2.107861982/2.110913372
on older `cb4b2f84`, not current cache/DDR-backed qualification.
