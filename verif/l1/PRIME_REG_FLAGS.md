# Register-only flags for branch read priming — 2026-10-13

Status: **isolated core experiment; not promoted, synthesized or deployed**.
The measured PRIME-CS parent is **33.958163543 MHz** synthesized/unplaced,
below the **40 MHz** requirement. No timing or area gain is claimed here.

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
The mapper must still establish the additional flags logic's area cost.

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
Independent closure: `prime-reg-core-audit-r1.json`.
Closure SHA-256:
`f826b73fd800c991ce937cdee74f85502cca05db7be88abf35c6167b6db13bed`.

Parent model SHA-256:
`73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca`.
Candidate:
`0070aec34169c368f11fb723f33aaeb8f60f0617d9e2f33948e2cd347567c143`.
Changed header:
`1f677f3cc7cd43ccea0d05edb564296865e58bd354795810383794b8ab0f077a`.

Qualify the exact FPGA-profile transfer, extend regression coverage as required
by that flow, and measure matched synthesis area/timing. Do not claim ≥40 MHz from
the programmed clock. Standard suite, physical UV-fast Win95/Quake, duration-
valid CoreMark and Doom gameplay/FPS remain open. Combine the independent SMSW
repair explicitly before any eventual replacement-image acceptance run.
The canonical gate must still be made genuinely green. No Vivado was launched
for this derivative. The synthesis flow's disk reserve must be restored before
launch; only regenerable compiler caches were deleted in this round, with
source/model/evidence pins rechecked afterward.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V IPC**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**; it predates this candidate and is not physical
FPGA/Doom IPC.
