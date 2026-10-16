# Boundary-only fetch staging experiment — October 16, 2026

**Private experiment, not promoted, synthesized, routed or deployed.** It
preserves architectural results in the checks below, but still has a measurable
boundary-fetch cost. No frequency improvement or gameplay gain is claimed.
Production RTL and both existing cold Quake simulations remain unchanged.

The retained corrected-wrapper timing parent is **34.652436 MHz synthesized /
unplaced**, not 40 MHz sign-off. Its reported 97-level worst path crosses live
instruction alignment, slow length decoding, demanded fetch width, routing,
paired-store admission, backing ACK and GPR writeback. The earlier combinational
[backing-direction experiment](../l1/BACKING_DIRECTION.md) regressed frequency.
This experiment instead introduces an actual register boundary.

## Design and measured tradeoff

[First recipe](prepare_sfetch_beat_stage.py): prepare a demanded `S_FETCH` beat
for one clock, then retain its valid bit and exact size until a qualified
`fsm_case_enabled && mem_req && mem_ack`. A walk returning to `S_FETCH` retains
that owner; reset, another state, or another producer's walk cancels it. The
existing decoder supplies the original demand/header policy. An assertion
checks issued size and ownership against that live policy. Request suppression,
translation, segmentation, fault priority, byte-valid accounting, actual memory
response and fast U/V execution remain in their existing machinery.

**Reject this broad version for its throughput cost.** A prefix-heavy 16-bit
protected-mode loop at a page edge, AXI latency7, rose **43 → 62 clocks
(+44.19%)**. All 96 measured whole-fixture comparisons added clocks. Passing
architecture tests does not justify adopting that cost.

[Narrowed recipe](prepare_sfetch_boundary_stage.py): stage only genuine
page/CS/IP boundaries. The existing `sfetch_interior16` path already has a
fixed-width payload independent of the length decoder, so it retains its
original combinational demand and four-byte width. `S_PIPE` is untouched. This
is a general address/segment policy, with no program, PC or workload special case.

| Measured comparison | Boundary-only result |
|---|---|
| 72 interior loop/latency cases | Whole-fixture clocks **and every warm-loop interval identical** |
| All 96 loop/latency cases | 73 whole-fixture totals and 77 warm-loop sequences unchanged |
| Worst selected boundary-prefix loop | **43 → 58 clocks (+34.88%)**, still a cost |
| Original 22 fault fixtures × AXI delays0/7 | 0–47 added clocks; worst whole-fixture increase **0.4724%** |
| Canonical `mb_brrandom` complete cycle trace | **30,125 → 30,146 clocks**, +21 / **0.06971%** |
| Other 19 canonical cycle streams | Exactly parent-identical, **not cycle-band passes** |

These are directed measurements, not a CoreMark score or a gameplay estimate.
The remaining boundary cost must be weighed against an actual frequency result
and measured full-PC throughput before promotion. In particular, do not label
this version generally cycle-neutral or use the 72 interior controls to hide
the page-edge regressions.

## Closed verification

Evidence root:
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
Every new build/run uses that external filesystem and bounded native owners.
The shared heavyweight lock was retained; no Vivado ran during this experiment.

- Six recipe/adapter tests pass. Exact-parent hashes reject drift and
  reapplication. Both derivatives change only `rtl/core/core.sv` and
  `core_fetch_decode.svh` across the 195-source directed-core closure.
- [Extracted actual stage tests](run_sfetch_boundary_stage_leaf.py) pass in
  both default and interior-16 profiles: **28,672 checks each**, including
  4,096 beats, 2,048 walk detours, 512 resets, 1,536 cancellations and 8,192
  backpressure/unqualified-ACK observations. The interior profile additionally
  passes **12,288 checks / 4,096 no-extra-clock transfers**. All five independently
  compiled broken versions fail in each profile: bypass, lost walk owner, raw
  ACK, stale reload and wrong width. This is an extracted sequential test,
  not arbitrary whole-core formal proof.
- Broad model `a3fcb483b72cf6de3b6f7778a6df3ce342cf62d934185329125c46bfe24f94dd`
  builds in **20.27 seconds**. Narrow model
  **`e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a`**
  builds in **19.66 seconds**. Both retain the parent's 153 definitions,
  assertions, full caches, UV/system/relocated fast paths and `AXI_LINE_REPLAY=0`.
  Each uses its own model-dependent harness basename, local object and generated
  header dependency. The guarded build uses 32 compiler jobs.
- [Cold fault corpus](run_sfetch_boundary_checks.py): **22 original guests /
  176 RTL executions / 88 complete QEMU comparisons** pass for each derivative.
  The narrower candidate has 21,832 functional records, 4,968 actual V
  retirements and 44 overlength-probe witnesses; **24.81 seconds**. Exact
  architectural parent/candidate equality is retained; cycle costs are reported
  separately, not normalized or called a cycle-equivalence pass.
- The same driver runs **48 cache-enabled real/16-bit-protected/paged guests**,
  two models, AXI delays0/7, and functional/cycle observation: **384 RTL
  executions / 192 measurements per derivative**. All complete QEMU state
  comparisons, guest exits, actual paired controls and AXI activity checks pass.
  There are 96 matched timing comparisons, summarized above. No OOM or PID-limit
  events; children are waited and reaped. These are cold-reset microbenchmarks.
- [Finite-CS diagnostic](run_sfetch_boundary_finite_cs.py): eight unchanged
  flat/relocated limit-boundary images × two models × delays0/7/31 × two
  observation modes = **96 executions**, all pass in **4.49 seconds**. Requires
  exact #GP(0), original fault EIP, guest frame/restart checks, complete
  architectural A/B equality, real AXI activity and paired controls. Candidate:
  3,048 functional records and 264 cycle-observed V retirements. This is an RTL
  diagnostic: the original QEMU finite-CS discrepancy remains unwaived.
- [Fresh private-reference corpus](run_sfetch_boundary_func.py): **108/108**
  pass in **107.39 seconds**, CPU20–23, no OOM. The
  [independent audit](audit_sfetch_boundary_func.py) regrades all **80,800 records**,
  checks **30,132 actual V retirements**, unchanged executable images and
  **12,397 input pins**. Removing optional masks yields **105 passes / the same
  three historical failures** (`tx_regform`, `tx_regform2`, `tx_stack`). No mask
  was added or expanded. Private QEMU remains
  `998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85`;
  it was not promoted over the canonical reference.
- **Canonical `make verify` remains FAIL**, native make exit2: **7 functional
  PASS / 101 FAIL** for both derivatives, in 396.97 / 399.56 seconds. The
  unchanged wrapper also correctly rejects `mb_brrandom`'s +21-cycle A/B
  difference. No golden, comparator mask, instruction cap or timing band was
  changed. Neither derivative is a canonical or standard-suite pass.

No snapshot, debugger STEP, intended-V breakpoint, pairing disable, global
slow-mode switch or guest patch was used in these runs. Core execution uses
`--cycle-func --l1-axi` / `--cycle --l1-axi`, not merely an AXI build define.

The first broad build launch omitted the guard's required `--` and stopped
before compilation. The first narrow launcher omitted its Python entry-point
call and likewise produced **no build** despite exit0; the native entry-point
test now catches that mistake. The real successful build owners are
`ventium-sfetch-beat-core-oct16-r2.service` and
`ventium-sfetch-boundary-core-oct16-r2.service`. Neither earlier launch is counted
as a build pass. An early functional-audit attempt ran before the canonical
ELFs existed; it was rerun after closure without relaxing artifact checks.
For the collected functional service, the audit binds its terminal native JSON
to the exact journal invocation instead of accepting an empty systemd ID.

## Remaining acceptance and current gameplay

Next: full-PC transfer and benchmark cost measurement, then a matched bounded
synthesis measurement if the performance tradeoff is acceptable. The external
volume had about **5.2 GiB free** at closure: preserve the established admission
reserve, prune only verified closed/rebuildable artifacts if needed, and do not
launch a large run that exceeds it. No timing improvement is established yet.
Canonical repair, full standard suite, ≥40 MHz synthesized/routed closure,
candidate FPGA Win95 cold desktop/UI and a completed Quake timedemo remain open.

The newer [older-model gameplay audit](../../fpga/audit_decode_bus_gameplay_window_r2.py)
checks **0.49046518 total U+V IPC** on
`7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68`, cycles
**1,600,065,247–1,700,065,247**: 37,998,050 U and 11,048,468 V retirements
in 100,000,000 clocks. U-only IPC is **0.37998050**, not total architectural IPC.
It checks live process ownership, UV-fast configuration, 13,858 input pins,
actual counter spacing, no OOM and two raw, visually inspected gameplay frames.
This is a post-hoc window, **not timedemo completion or FPGA performance**.
It predates the V-result, input and current fetch-stage candidates; those
candidates still have **no verified gameplay IPC**.
