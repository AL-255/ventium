# FRNDINT reference repair and cold-core differential qualification

October 13, 2026. **Private reference qualified for these instruction tests;
not promoted to canonical QEMU.** No RTL, guest payload, comparison mask,
cycle band, canonical golden, or FPGA image changes in this stage.

The [isolated RTL repair](../../sys/frndint/README.md) exposed a missing DE flag
in the preceding reference. Broader native tests now establish **3,972 failing
FRNDINT cases** in that reference, including numeric and exception errors.
The repaired private reference has zero failures on those same fixtures.

## General fix

`prepare.py` replaces only `helper_frndint` in the exact SHA-pinned
[composed reference](../c1_reference/README.md). It:

- Detects nonzero exponent-zero operands, including pseudo-denormals. Masked
  DE continues; unmasked DE preserves ST0 and prevents rounding/PE.
- Preserves ST0 on unmasked invalid operands; masked invalid operations retain
  SoftFloat's quiet-NaN/indefinite result policy.
- Handles empty ST0 with IE/SF, clears C1, and writes indefinite only when
  masked. This is not a general repair of other QEMU x87 stack instructions.
- Uses extended precision for FRNDINT itself, independent of PC, then restores
  the previous internal precision setting. RC remains effective. A following
  FADD verifies that ordinary arithmetic still obeys PC.
- Preserves instruction-specific C1 and existing sticky exception merging;
  does not globally alter SoftFloat denormal or rounding policy.

The PDF skill guided inspection of the Pentium Volume 3 FRNDINT page (printed
25-128 / PDF 745) and section 7.1.11 (printed 7-23 / PDF 214): unmasked denormal
exceptions must leave operands unchanged. The local
[241430-004 manual](../../../ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf)
was not edited. Native x87 is an independent defined-result oracle, not P54
silicon timing or an oracle for undefined C0/C2/C3.

## Verified evidence

| Check | Result |
| --- | --- |
| FRNDINT native instruction comparison | 28,612 pass; parent fails 3,972 distinct cases |
| Independent integer-only oracle | 27,072 normal/zero cases agree |
| Adjacent FIST64/FST32/FST64 controls | All 72 unchanged from the parent |
| Full-stack / exception-priority / sticky-status tests | 5,472 pass, including 96 following-FADD precision-retention cases |
| Earlier C1/arithmetic/remainder regression | All 34,200 pass; numeric results and unrelated status bits unchanged |
| Cold 412-case program, complete unmasked comparison | All 11,129 architectural records match; native and guest exit 0 |
| Unchanged 108-program functional corpus | 108 pass, 80,800 complete records; no mask changes |

The FRNDINT fixtures cover RC/PC combinations, both signs and old C1 values,
exact values/ties/precision boundaries, +/-2^63, large integral values, signed
zeros, denormals/pseudo-denormals, infinities, QNaNs/SNaNs, unsupported encodings,
and masked/unmasked IE/DE/PE. Parent mismatch categories overlap: 3,538 numeric,
2,004 defined-status, 724 C1, and 1,860 exception mismatches.

Additional state cases exercise all eight IE/DE/PE mask combinations and
pre-existing masked ZE/OE/UE flags. They compare CW, TOP, defined FSW bits, tags
and all eight physical FP payloads. Undefined condition codes and native-vs-QEMU
saved-pointer/selector presentation are not asserted by that native probe.
The separate full cold-core differential trace uses **no added masks** and
checks all normal comparator fields, including saved pointers.

The first attempted comparison reused the earlier RTL trace with initial ESP
`0x408002e0`, whereas the new QEMU invocation started at `0x40800790`. Both
guests completed all cases, but the full comparison correctly failed at record
zero. That failed owner/trace is retained. `run_aligned.py` cold-runs RTL again
with the newly observed QEMU initial ESP (`0x408007a0` for that invocation),
just as the standard worker aligns loader state. The first instruction is
XOR EBP,EBP, so observing its post-state does not hide an ESP change. No trace
field is rewritten, removed or masked to obtain the passing result.

Cold-core identity remains
`2050b71430b39fc5059a8f2be6beeae74e232b279d21b2b0541a1e16b7d35d63`.
It runs `--cycle-func --l1-axi`, AXI read/write latency 7, UV/system/relocated
fast paths enabled, with no STEP or breakpoint. Cold directed trace: **2,474 V
retirements**; functional corpus: **30,134 V retirements**. These are not
gameplay measurements. The functional run took 111.09 s. A second comparison
without the corpus's pre-existing stack masks passes 105 programs; the same
three deliberate stack-fault programs remain unmasked failures.

## Source, resources and reproduction

Evidence root: `/home/yukidama/external/tmp/ventium-qemu-frndint.wRXifJwr`.

Private QEMU SHA-256:
`da49b8105f90b4257494a7b7f1e57e5428fa66dc667278b824d381d9d0e9f84d`.

| Receipt | SHA-256 |
| --- | --- |
| `build-r1/closed.json` | `0f45141f53fe6d35877a7cb9cb3e10fe3317e4b943fef37d92b7191f840cab36` |
| `probe-r1/closed.json` | `ed6e64f7bb8b8caacae4ff0ea7c9e572d3a0b5b8668a1af753eff60b1835ee80` |
| `state-r1/closed.json` | `b63c8ab3b2943482d5a686a512743621a045393a8a673f0290dab5f2b72038a7` |
| `aligned-r1/closed.json` | `8b0235cb3ce5f440e4380b701879175b9454af862ec0276705d3bef1978a16fd` |
| `func-r1/closed.json` | `bc1f637ff033ecb8da6dd4d307d1ac8ebab9131c9e331112556bd0cf3c00ad6c` |
| `c1-r1/closed.json` | `d34a63a4eba3d92cf0135defc8264e25464a0293ec3a338ae6b7b9bd3f22ea6e` |
| `audit.json` | `5efd6ee2365ac757517ec858cc393c7326a8178cdb093ee4ab8d3b2d233080af` |

The independent audit rechecks **25,562 input pins**, all **11,132 source
files**, the exact one-helper delta, native/exact records, full cold traces,
all 108 comparisons, actual functional-worker affinities and terminal owners.
Both native probe executables are executed again during the audit.

All seven owners are closed (MainPID 0). The initial mismatched-ESP comparison
remains exit 1; the six successful owners exit 0. Build owner invocation
`457ef08fdd5347958ecee86ea25ffa51` contains the guarded scope invocation
`72e6b3932abe405fa6ddfa89eb1e617e` in its start/stop interval. Fresh-source build:
29.19 s, 32 compile jobs, peak **3,232,923,648 bytes**, zero recorded swap peak.
The 350 MiB reference-build disk budget was based on the measured 233 MiB
parent source/build footprint and remained above the 4 GiB reserve. This did
**not** admit a larger RTL/Vivado build. After tests, free space is about
4.62 GiB, still below the >5 GiB heavy-RTL admission threshold. No cleanup,
Chrome termination, concurrent Vivado, or board write occurred in this stage.

Use fresh output leaves, external TMPDIR and bounded systemd owners:

- `test_prepare.py`: `QEMU_FRNDINT_PARENT` names the exact parent helper;
  source drift and repeated application must fail.
- `build.py --out FRESH`: named guarded `ipc_parallel32` scope, CPU8-15,
  explicit Verilator path in the systemd environment, 600 s owner cap.
- `run_probe.py` and `run_state.py --build BUILD --out FRESH`: CPU12,
  1 GiB/no-swap, 180 s owner cap.
- `run_aligned.py --build BUILD --probe PROBE --out FRESH`: CPU13,
  1 GiB/no-swap, 240 s cap. `run_integrated.py` preserves the failed first
  experiment; it is not the passing reproduction command.
- `../c1_reference/run_probe.py --build BUILD --out FRESH`: CPU12,
  1 GiB/no-swap, 180 s cap, unchanged earlier regression.
- `../../sys/frndint/run_func.py`: unchanged model/job rebinding wrapper;
  CPU8-11, four workers, 2 GiB/no-swap, 600 s cap. Pass the frozen parent/core
  from the RTL repair report and this build/probe.
- `audit.py --root ROOT`: CPU12; requires all named R1 owners closed and
  refuses overwriting its result.

## Remaining acceptance

This removes the newly found FRNDINT reference blocker; it does not make the
whole FPGA effort complete. Canonical QEMU and its caches were not replaced.
The last unchanged canonical run still reports **7 functional PASS / 101 FAIL**,
with existing cycle-band failures. The new private full functional result is
separate evidence, not relabelling of that canonical run.

Next work must deliberately qualify/promote the composed reference into the
reproducible gate flow, retain stack/system-mode caveats, and address cycle
gates. Hardware timing, both CoreMark correctness seeds, cold Win95 desktop/UI,
full Quake timedemo, target performance and physical UV-fast acceptance remain
open. Latest earlier unplaced synthesis estimate is **35.057 MHz**, below
40 MHz; no new timing or area result exists. Existing-bitstream Doom still has
no FPS because it faults before gameplay.

Candidate gameplay IPC is **unmeasured**. Older verified **simulation** baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237-1,300,065,237**. It predates this candidate and is not FPGA/Doom IPC.
