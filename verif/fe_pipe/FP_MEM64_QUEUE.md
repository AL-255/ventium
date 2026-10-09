# Ordered m64 x87 queue — October 9

Private prototype, **not production/standard-suite/FPGA acceptance**.
Verified gameplay is **0.44468922 total U+V IPC**, model `59650fe2`,
clocks **1,200,000,000–1,300,000,000**. That measurement predates this change,
scalar dispatch and read-retirement priming. CoreMark's full REP direct-memory
scores remain **2.107861982 / 2.110913372 CM/MHz**, not this candidate's scores.

## Two separate changes

`prepare-fp-mem64-queue.py` widens the existing one-entry FXCH/m32 admission
slot, rather than adding an FPU or speculative architectural state. The added
`VEN_FP_MEM_QUEUE64` flag permits completely acquired FLD64/FILD64 and six
non-pop m64 arithmetic forms. It adds 32 payload bits and one width bit; TOP,
tags, ST0, arithmetic and conversion still belong to the existing leaf.

Both core ownership lists are extended: allocation of deferred load responses
and the last-old-response/immediate-load assertion. The wrapper retains its
one-slot capacity, masked-exception admission and ordered response contract.
The core still requires the complete checked operand before issuing a command.
No ACK/ready dependency was added to the raw shape predicate. Translation,
fragment handling, exception/debug drain and actual bus requests are unchanged.

The new regression exposed a **pre-existing protected-mode FDP bug** in both
parent and prototype: the shared FPU received `dbase + q_ea` as its saved data
pointer. FNSTENV requires the offset paired with the saved selector in protected
mode. This is documented in Intel's manual, sections 8.1.8 and 8.1.10.
([Intel Volume 1](https://www.intel.com/content/dam/support/us/en/documents/processors/pentium4/sb/25366521.pdf))

`prepare-fp-dptr-offset.py` separately changes only the metadata input to
`seg_real ? (dbase + q_ea) : q_ea`. The memory address remains linear and
translated. Existing real/V86 pointer values are preserved; this is **not** a
qualification or repair of their environment-image encoding. The legacy
non-shared `fpu_writeback.sv` path is also outside this fix and still needs
its own pointer-format audit.

## Evidence and retained failures

All roots below are beneath `/home/yukidama/external/tmp/`.

- `ventium-fp-mem64-queue.r1W3rCBu/leaf-r3`: parent and disabled candidate
  each pass the original 12 leaf checks; enabled candidate passes 25. Actual
  older/younger state images, TOP/tags, FIP/FDP/selectors, input poisoning,
  unmasked rejection, capacity and reset are checked. Low fraction and signed
  high-dword operands catch truncation. The unchanged parent with the wide
  test enabled fails at real wide admission, as required.
- The first leaf launch refused missing setup inputs; `leaf-r2` subsequently
  hit the fixed task cap through compiler-cache process overhead, not OOM.
  `leaf-r3` passes with caching disabled, still 32 aggregate compile jobs,
  16-GiB/128-task bounds and six structural hard-error classes.
- Initial wide-only board model `d295b5b7` passes the 64 flat smoke comparisons.
  Its `matrix-r1` **FAIL** is retained: 128 flat cases pass; all 128 relocated
  executions fail the guest's saved-FDP check in both parent and candidate.
  The QEMU guest passes. No expected value or comparator was weakened.
- Initial pointer correction used `real_mode`; its successor uses `seg_real`
  to avoid inadvertently changing V86 values. Earlier models/results remain
  separate, not overwritten or presented as the final candidate.
- Final pointer-only root: `ventium-fp-dptr-r2.dG0pvlBe`, board model
  `88b73822c6276074344e347c9541e29c8950a427da33f5470dd33c9cbb4b8b4e`.
- Final wide-plus-pointer root: `ventium-fp-mem64-r2.LCJyV4S0`, board model
  `d18116278630cb2f8733ce5a0c54aceae37ca677a6cf7d900fa4bf5f937660cf`,
  full-address user model
  `7f555c1b55a36bfc85f05d62aca9726ddb29d5d0ca556163391cb83c24da85e7`.
  Source pins, native build exits and model-local generated headers pass.
- `matrix-r5`: **256 complete QEMU architectural comparisons**, each with a
  cycle execution. Eight operations × drained/overlapped × flat/relocated ×
  aligned/cache-line crossing × two models × AXI latencies 0/7. Every program
  checks results and saved metadata and requires actual V pairing. All 128
  matched complete-program totals and steady windows are nonregressing.
  All forced-FWAIT controls are exactly unchanged. Actual queue acceptance
  and integer retirement with two pending owners occur for all eight forms.
- `fault-r4`: **24 complete QEMU comparisons** plus cycle executions.
  FADD64/FLD64/FILD64 × absent first/second operand page × two models ×
  AXI latency 0/7. The handler checks error/EIP/CR2, older completed divide
  result, old metadata, unmodified stack depth and no younger integer effect.
  Only the PTE is repaired; restart produces the exact result. Warm calls
  prove actual queue use; no partial operand may reach the FPU.
- `int3-r5` / `gp-r2`: **128 complete comparisons each**, plus cycle
  executions. A real INT3 or faulting selector load follows the independent
  integer work, with flat/relocated CS/DS and drained controls. Each of sixteen
  handler visits checks the exact saved return state, completed FP metadata
  and TOP. Full traces check all stack values, and the ordinary loop verifies
  its result after IRET. All eight forms have actual queued-operand and
  two-pending-owner integer-retirement witnesses; controls do not queue.
- `irq-full-r1`: **64 complete instruction-stream comparisons and 64 separate
  IRQ-entry-state comparisons**, each accompanied by a cycle execution. Eight
  forms × drained/overlapped × two models × AXI latencies 0/7. Every run has
  sixteen real IRQ deliveries; all sixteen candidate overlap combinations
  have fourteen requests with two FP owners still pending. INTA requires zero
  owners. Guest metadata, TOP, return frame and final result checks pass.
  The oracle pulses a real QEMU master-PIC IRQ5; RTL drives only its existing
  external pins. No guest registers or internal RTL state are injected.
  This is flat-CS standalone PIC/core-pin coverage, not full-PC IRQ acceptance.
- Five recipe tests cover source drift, repeated application, both load-owner
  anchors, disjoint copies and existing-output preservation.
- Two additional tests guard event-fixture generation and unique QEMU ports.
  The initial event fixture omitted the IDT page mapping; its QEMU #PF/DF
  diagnostic and stopped run are retained. Two subsequent fixture failures
  exposed pinned-QEMU metadata limitations: FLDENV ignores saved pointers,
  and FNSTSW AX changes FIP. The final handler reads FSW from its saved
  environment and does not mutate/restore FP pointers. No trace field or
  result check is removed; the complete handler state is compared to QEMU.
  `matrix-r4` failed during oracle preparation when two concurrent producers
  received port 60751. The final runner refuses within-run port reuse. All
  four matrices above were rerun successfully with that runner.
- `hardware-lint`: original parent, pointer-only and final candidate all pass
  with `SYNTHESIS`/`VTM_NO_DPI` and six hard structural classes. This is **not
  Vivado synthesis, timing, placement or resource evidence**.
- `system-matrix`: 76 complete QEMU comparisons and parent architectural
  parity pass. The unchanged generic `make verify` **still FAILS**: 7/108
  functional passes, 101 terminal-length mismatches, and four cycle bands
  (dependent-add 1.133, independent-add 0.639, D-miss 5.000, I-miss 13.003 CPI).
  A fresh parent execution with identical ELF/loader inputs matches all 108
  complete architectural traces, including terminal states. This establishes
  nonregression on that corpus, **not** a generic-gate pass.

`qualification-r2-closed.json` rechecks the final source/test pins and keeps
`generic_gate_passed`, `standard_suite`, `production` and `fpga_qualified`
explicitly false. Directed qualification is not an acceptance waiver.

## Full-PC integration, not launched

`ventium-fp-mem64-soc.nqs8uA9x` builds model
`842f0c7d37f9936c7e02982b3ec7dbd753e5950c37d4cea2161a11129332f389`.
Only `core.sv`, `core_fp_async.svh` and `ven_fp_fxch_queue.sv` change from the
read-prime PC source. Every core/FP file matches the microtested candidate;
the profile adds only the wide flag (128 unique defines). U/V, fast system
and relocated paths, full P5 L1s, 32-KiB platform L2, posted16 and registered
read-first Xilinx memory modeling are unchanged. Native build, source pins
and local host/header checks pass; the same 98 third-party structural
warnings remain. No new cold guest, standard-suite or FPGA run is launched.

## Directed performance, not gameplay

Aligned flat steady iterations, excluding the first four of sixteen calls.
Complete cold-program timing is also checked. These loops include environment
checks and stack cleanup: the numbers are not bare instruction latencies.

| Younger operation after FDIV | AXI latency | Parent → candidate clocks/iteration | Clocks saved |
| --- | --- | --- | --- |
| FADD/FMUL/FSUB/FSUBR64 | 0 | 170 → 165 | 2.94% |
| FADD/FMUL/FSUB/FSUBR64 | 7 | 400 → 395 | 1.25% |
| FDIV/FDIVR64 | 0 | 201 → 200 | 0.50% |
| FDIV/FDIVR64 | 7 | 431 → 430 | 0.23% |
| FLD/FILD64 | 0 | 171 → 163 | 4.68% |
| FLD/FILD64 | 7 | 401 → 393 | 2.00% |

No percentage of Quake improvement is assigned to this change. It is not yet
present in a measured gameplay build. The dominant last-measured pipeline
memory wait remains 21.12% of clocks; this queue cannot eliminate that category.

## Reproduction and open gates

Create a private source with the pointer recipe, then the wide-queue recipe.
Build matched models with all existing U/V/fast-system/fast-memory flags; add
only `VEN_FP_MEM_QUEUE64` to the second. `run-fp-mem64-queue-leaf.py` accepts
`--parent`, `--candidate` and `--out` source directories. Whole-core
`run-fp-mem64-queue.py` takes `--control`, `--candidate` executables and a new
`--out`; repeat with `--fault` for source-page faults or `--event int3` /
`--event gp` for post-queue events. Use the existing bounded
`tools/build_scope.sh`, explicit external TMPDIR and the `ipc_parallel32`
profile. Neither runner accepts snapshots or trims architectural traces.

Do not promote solely on these directed passes: the mandatory generic
UV-fast/AXI gate has known terminal-observer/cycle-band failures, and complete
standard-suite, relocated external-IRQ/wide-queue debug-event, full-PC gameplay, hardware resource/timing
and FPGA deployment qualification remain open.

## Combined scalar-dispatch integration

`ventium-fp-combined.gkqX3v51` applies the existing scalar-dispatch recipe to
the final pointer-corrected wide-queue source. It changes only `core.sv` and
adds `core_fp_scalar_dispatch.svh`; all other payload files remain identical.
The only additional define is `VEN_FP_SCALAR_DISPATCH`.

- Board-core model: `7bfb9e32c7799ef9c3da80beff73e29cdc2501281da93cc545a80e408404e297`.
- Full-address user model: `3f6373157ceecfe6f15b66e731da8ccad706e198d468c3f8bb9fd22aa4f03197`.
- Existing scalar gates against the wide-only parent pass **356 complete QEMU
  comparisons**: throughput 288, debug/#NM events 4, CPU-store SMC 16 and
  store-page faults 48, plus cycle executions. Complete-program and 223-iteration
  steady throughput windows remain nonregressing. Selected conversion loops
  improve 8→7 clocks; this is not a gameplay attribution.
- The combined m64 driver against the pointer-only parent passes all **536**
  overlap/operand-fault/INT3/#GP comparisons and their cycle executions. It
  retains every original state, fault, owner and pairing assertion. FWAIT
  controls may benefit from scalar dispatch, so their timing must be
  nonregressing, not necessarily identical. No isolated queue gain is inferred.
- The new external-IRQ gate also passes **64 instruction plus 64 entry-state
  comparisons** on the combined candidate. All overlap combinations again
  record fourteen two-owner IRQ requests per sixteen deliveries. The earlier
  24-case smoke pass remains separate evidence.
- All **76** broad system comparisons and three synthesis-guard lint profiles
  pass. Native builds, local generated-header dependencies and source pins pass.
- Generic `make verify` remains **FAIL**, with the same 101 terminal-length
  mismatches and four hard cycle bands. A new matched-ELF/loader execution
  agrees with all **108 complete parent architectural traces**. This does not
  turn the generic gate green or waive it.

`run-fp-combined-mem64.py` is a fail-closed adapter around the existing m64
driver; its only semantic differences are the two-flag profile and FWAIT
timing rule above. `run-fp-mem64-irq.py` preserves raw traces, separately
compares exactly identified interrupt-entry ABI records, and then compares
every real instruction, including the resumed boundary instruction. Two
adapter and two IRQ fixture/record-accounting unit tests pass.

No combined CoreMark, gameplay, standard-suite or FPGA result is claimed.
An initial user-build admission was refused below 4 GiB free, before launching
a compiler. Eight explicitly selected closed-build PCHs were losslessly
archived with verified recovery hashes, recovering **616,544,045 bytes**;
binaries, inputs and run evidence remained unchanged. The build then passed.

The combined full-PC source now also compiles successfully in
`external/tmp/ventium-fp-combined-soc.WPpVLjvn`: model
`652de481d967acee7a3bf48c419136053ec8625e93566fb1091a4a1ca66dc350`.
Relative to the wide-only PC parent, the only added feature is scalar dispatch
(129 defines total); both changed core files match the directed candidate.
The actual four-way registered/read-first XPM fields, local harness/header
dependency, source pins and unchanged 98 third-party structural warnings were
checked. UV-fast, full P5 L1s, 32-KiB platform L2, posted16 and 40/40/80-MHz
settings are unchanged. This is build evidence, not guest or FPGA acceptance.
Six more closed-build PCHs were losslessly archived with verified hashes,
recovering **472,079,414 bytes**; receipt:
`external/tmp/ventium-combined-soc-pch.xmOyE6vW/closed.json`.
