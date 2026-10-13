# Register-only flags for branch read priming — 2026-10-13

Status: **isolated core/full-PC experiment; synthesis/timing audit closed;
not promoted or deployed**.
The measured PRIME-CS parent is **33.958163543 MHz** synthesized/unplaced,
below the **40 MHz** requirement. The candidate estimates **35.023816195 MHz**
and uses 852 fewer LUTs under the matched mapper. It still misses 40 MHz.

## Change and reason

The parent's worst estimated path is EIP → address/translation → memory
response → U ALU flags → paired-V branch outcome → next-read commit → L1D LRU:
103 levels, 29.237 ns data delay. The branch-prime guard already requires a
non-memory U instruction, so this consumer need not read memory operands.

`prepare_prime_reg_flags.py` changes only `core_mem_chain.svh`. A flags-only
`u_pipe` instance uses the existing lane-selected GPR operands; it shares the
existing register shifter outputs. Only this hint's commit decision uses the
cofactored branch result. Architectural execution/branch resolution, request
addresses, offers, ownership, exception priority and clock sequencing are
unchanged. Full commit equality and guarded branch equality are asserted.
The measured mapper area and timing effects are recorded below.

The separate SMSW repair needed by DOS Doom is deliberately not mixed into
this one-change timing comparison. The old FPGA image still fails Doom
startup: [physical result](../../docs/FPGA_DOOM_2026-10-13.md).

## Closed checks

- Six leaf profiles: branch priming off/predicted/fallthrough-only × immediate
  ROR off/on; **393,216 comparisons**, including memory-input anti-vacuity.
- Stale ALU flags, stale shift flags and inverted prediction mutants all fail.
- Source-bound SMT abstraction: six equivalence queries UNSAT, two real-offer
  witnesses and two wrong-prediction mutants SAT. Shared ALU/condition helpers
  are uninterpreted; this is not a whole-core proof.
- Fresh full-core Verilator build: 195-source closure, unchanged 152 UV-fast
  definitions, real AXI, assertions and six hard structural warning classes.
- All eight existing core corpora pass, **4,240 probe runs**, with complete
  architectural/cycle equality and unchanged hint/ownership counts.
- Added cold branch corners pass full QEMU and A/B state/cycle comparisons:
  72 candidate runs exercise **384 shift commits**, **384 preserved-flag
  commits**, and **24 rejected predictions** (plus 24 accepted alternating
  outcomes). Counts include both trace modes, alignments, relocation and AXI
  latencies; they are not benchmark performance samples.
- Six recipe/driver unit tests pass. Independent leaf binary and solver replay
  passes. Full-core closure audit passes. The **108-case / 80,800-record**
  canonical same-input replay exactly matches parent, candidate and the
  original candidate traces. This is regression evidence, not a QEMU pass.
- Canonical `make verify`: **7 PASS / 101 FAIL**, native exit **2**. All 20
  cycle traces exactly match the parent. This remains a failed gate.
- Full FP matrix: **1,536 measurements / 768 parent–candidate comparisons**,
  all cycle deltas zero. The additional 12-group regression closes successfully:
  six instruction-boundary positions, precise faults, integer, memory,
  held-request, branch and same-input replay. It takes 613.55 seconds with
  unchanged per-case limits. The replay remains regression evidence, not a
  canonical QEMU pass.
- Full-PC transfer builds successfully in **23.52 seconds**. All 102 common
  RTL sources match the directed core, with only `core_mem_chain.svh` changed;
  all 156 simulation definitions and posted-16 transport are retained. The
  native host compile uses its own generated root header. The parent's **98
  SoC structural diagnostics remain unchanged**; this is not clean full-SoC
  lint. Separately, strict CPU-hierarchy lint passes the frozen 158-definition
  hardware profile, with all six structural error classes enforced.
- Six FPGA transfer/controller tests pass, including rejection of source drift,
  a second changed file and weakened resource guards. The generated synthesis
  and read-only timing controllers preserve the matched mapper, watchdogs,
  40/100 MHz constraints and canonical failure. Synthesis has now launched as
  recorded below; the subsequent read-only timing audit has also closed.
- Both short cold CoreMark seeds complete with the reference CRCs and exactly
  unchanged ticks: **4,767,218 / 4,753,406**. The completed model records
  **1,055,307 / 1,054,254 V retirements**, respectively. Independent native
  closure checks pass (7,033 input pins, all children reaped, no OOM). These
  10-iteration controls are **not duration-valid scores or the standard suite**.

The first Icarus leaf attempt hit its 50-second limit without a result; it is
retained as a timeout, not a pass. The successful leaf uses Verilator.
No mask, golden or timing-band changes are allowed to waive canonical failures.

The canonical controller's 660-second timeout included its wait behind the
297-second A/B suite. Its child subsequently completed, but the controller had
already exited. The build guard's durable native `result` file contained `2`;
the scope was inactive and all 128 worker results were present. The recovery
script copies the marker/journals, checks all input pins and cycle comparisons,
and records both native failure and controller timeout. It does **not** infer
success or an exit code from log wording. The first replay refused the absent
closure receipt; replay `r2` uses the recovered evidence. Future canonical
controllers should start after the preceding guarded job closes, not queue
inside that outer watchdog.

## Identity and remaining work

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.
Subdirectories: `prime-reg-leaf-r3`, `prime-reg-proof-r1`, `prime-reg-core-r1`,
`prime-reg-ab-r1`, `prime-reg-corners-r1`, `prime-reg-replay-r2`.
Extended checks: `prime-reg-fp-r1`, `prime-reg-regressions-r1`.
Full PC/export/lint: `prime-reg-soc-r1`, `prime-reg-fpga-r1`, `prime-reg-lint-r1`.
Independent closure: `prime-reg-core-audit-r1.json`.
Closure SHA-256:
`f826b73fd800c991ce937cdee74f85502cca05db7be88abf35c6167b6db13bed`.

Parent model SHA-256:
`73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca`.
Candidate:
`0070aec34169c368f11fb723f33aaeb8f60f0617d9e2f33948e2cd347567c143`.
Changed header:
`1f677f3cc7cd43ccea0d05edb564296865e58bd354795810383794b8ab0f077a`.
Full-PC binary:
`693d73f5feed438c834bf09af34b72087309511b3d1cee65a20971cba2216e64`.
Frozen 190-payload manifest:
`3725586f494f96210da1c1f15ef56c614bcd8a3b41dbd042b02ffded7d964cd0`.
Extended closure:
`357e2ed80d9821bac0b5e03c32f530deea2f25bd69dd7b966bdd57fa019623c0`.

The full-PC build lowers its guarded compiler scope to **10 GiB RAM / 2 GiB
swap before executing any compiler**, checks the actual scope/caps, and retains
all original native arguments and the 600-second native timeout. It does not
queue behind another guarded build. The FPGA controllers retain the original
6 GiB starting disk admission / 4 GiB live floor, synthesis 8/6 GiB RAM/swap
caps and read-only timing-audit 8/4 GiB caps.

Closed A/B, FP and extended regression text artifacts are now byte-verified
lossless archives beside the runs; native models, pinned inputs, source,
receipts and media stay expanded. The four large closed PRIME-CS timing tables
and unpinned closed A/B fixture products are in
`closed-prime-reg-fixture-reserve.tar.gz` (restore under the evidence root).
`closed-prime-reg-regressions.tar.gz` likewise restores under the evidence root;
`closed-prime-reg-fp-text.tar.gz` restores under `external/tmp`. Re-running old
trace-consuming audits requires restoring their archived members first. The
archives do not turn historical failures into passes.
Additional archives preserve unpinned predecessor traces and current closed
fixture/compiler products. `closed-predecessor-traces.tar.gz` and
`closed-prime-reg-model-products.tar.gz` restore under `external/tmp`;
`closed-prime-reg-regression-fixtures.tar.gz` restores under the evidence root.
Compiler executables and headers remain available; only regenerable products
were moved into the compiler archive. All removals followed complete member
hash verification and current-input rechecks.

Measure matched synthesis area/timing. Do not claim ≥40 MHz from
the programmed clock. Standard suite, physical UV-fast Win95/Quake, duration-
valid CoreMark and Doom gameplay/FPS remain open. Combine the independent SMSW
repair explicitly before any eventual replacement-image acceptance run.
The canonical gate must still be made genuinely green. The first synthesis
controller admission at **10:37:59
UTC** exits 1 before creating `started.json`, launching Vivado or writing a
project: the retained measured-growth guard needs **more than 7,208,493,056
bytes (6.7134 GiB)** free, not merely the separate 6 GiB minimum. About 6.1 GiB
was free. Do not lower this guard or count this as a native synthesis attempt.
Retained controller: `ventium-prime-reg-synth-oct13.service`, invocation
`d3e2a47b023e4848854a7dcd0746b502`, MainPID 0 / native controller exit 1.
The reserve had to be restored before retry; its source, constraints and
resource limits were not changed.

**Resumed at 10:44:43 UTC:** lossless archival of older closed traces restored
6.9 GiB free, clearing both original admission checks. The **unchanged**
controller now runs as invocation `5889512f4f3840a2a791173d2141d533`, with
7,422 pinned inputs and the original 45-minute native bound. One controlled
Vivado build family owns synthesis; its parent, synthesis process and vendor
task worker share the guarded scope. At 10:57 UTC it remains live, with no OOM
or resource-stop condition. There is **no new timing/area result yet**.
The initial refusal is retained as `preflight-refusal-r1.json`, not erased or
converted to a tool pass. `closed-regression-replays.tar.gz` restores the old
trace outputs under the evidence root; all current input pins stayed expanded
and were rechecked. Historical output-consuming audits need restoration first.

The short CoreMark controller
`ventium-v-carry-cm10-prime-reg-oct13.service` closed 0, invocation
`90a975a4e1ed4beea7c4727ad6e17772`. No CoreMark worker remains. Its independent
audit is `prime-reg-soc-r1/coremark/audit.json`.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V IPC**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**; it predates this candidate and is not physical
FPGA/Doom IPC.

## Native synthesis closure — October 13, 11:17 UTC

The original synthesis invocation closes naturally with **exit 0 / MainPID 0**
after **1,989.91 seconds**. Independent `prime-reg-synthesis-r1/audit_closed.py`
passes: all 7,422 input pins unchanged, exact single-header RTL delta, same
158 hardware definitions, matched logic-only mapper, complete native DCP and
no OOM/resource-stop event. Peak guarded usage is **8.00 GiB RAM / 1.55 GiB
swap**, within the unchanged 8/6 GiB limits. No implementation starts.

| Resource | PRIME-CS | PRIME-REG | Delta |
| --- | ---: | ---: | ---: |
| CLB LUTs | 188,163 | 187,311 | −852 (−0.45%) |
| CLB registers | 55,011 | 55,006 | −5 |
| BRAM tiles | 277.5 | 277.5 | 0 |
| DSPs | 47 | 47 | 0 |

DCP SHA-256:
`66ff1ad84d0b4f64926b0cec6df965a0a54bbca60c49185b9799c69f454eb1da`.
Vivado reports zero synthesis errors, one critical warning and 1,564 warnings
in its synthesis summary. The critical warning concerns a generated PS IP
`create_clock` target; do not assume clock validity from the synthesis exit.
The separate native timing audit opens both projects, verifies actual
**40 MHz core / 100 MHz PL** constraints and structural DRC, and measures the
worst core paths with those constraints. It starts at **11:19:07 UTC** as
`ventium-prime-reg-clock-oct13.service`, invocation
`597338c6af22432283ab53e023a572ad`, under the original 15-minute native limit
and 8/4 GiB RAM/swap caps. It closes naturally at **11:27:01 UTC**, exit 0 /
MainPID 0, in **473.59 seconds**. Independent `audit_closed.py` passes all
7,437 input pins, unchanged parent checkpoint, actual 40/100 MHz clocks,
zero black boxes and zero checked structural DRC violations (MDRV-1/LUTLP-1).
Peak memory is 4.52 GiB, with no swap or OOM. This does not qualify all timing
constraints, routed setup/hold or physical operation.

| Matched synthesized estimate | PRIME-CS | PRIME-REG |
| --- | ---: | ---: |
| Core Fmax | 33.958163543 MHz | **35.023816195 MHz** |
| Setup slack at 25 ns | −4.448 ns | −3.552 ns |
| Worst core hold slack | −0.101 ns | −0.101 ns |

Estimated Fmax improves **3.14%**, with setup slack improved by **0.896 ns**.
This is not a gameplay speedup or routed sign-off. No false/multicycle path,
clock relaxation, cache reduction, U-only mode or execution stall was added.

The new worst path is `q_pc_reg[0]/C` → `pipe_mem_active_q_reg/D` and eight
replicas, **99 logic levels**, **28.341 ns** data delay (6.699 ns logic /
21.642 ns estimated routing). The report traverses legacy fetch/fault-length
decoding, fragment/address routing, paired-store intent readiness, backing ACK
and held-transaction ownership. `lock_session_q` is another near-critical
consumer. This is the next measured optimization target: separate an admitted
S_PIPE transaction's completion/admission from unrelated legacy fetch-decode
inputs, while proving precise fault, fragment, paired-store and consume/replace
ownership unchanged. Do not remove ACK guards merely because the path appears
mutually exclusive in a microbenchmark. The general read-owner and intent-ready
cofactors already present must not be duplicated as a purported new fix.

No placement, routing, bitstream or board run has started for this candidate.

Timing audit SHA-256:
`72686daa0769e08fcf6fa00580c7aeaa09ff06c47ed4c4a16827f300035832ae`.

The independent SMSW repair has also been composed with this candidate in a
separate compiled tree; see the [composition record](../sys/smsw_memory/README.md#compose-the-repair-with-the-timing-candidate).
That does not alter the timing comparison's frozen inputs or inherit its result.

The next isolated derivative now predecodes both possible cache-map endpoints
to shorten the late extent/routing path. Its microtests, source-matched full-core
build and exact-input regressions are closed; the canonical gate remains red
and timing is not measured. See [parallel endpoint-map decode](ENDPOINT_MAP.md).
