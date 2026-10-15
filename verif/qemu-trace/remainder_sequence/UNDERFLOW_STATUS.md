# Exact FPREM underflow — October 15, 2026

**Shared-FPU leaf repair passes; whole-core and FPGA qualification pending.**
The completed fetch-metadata FPGA synthesis contains the earlier numeric and
operand-exception fixes, but not this underflow fix. It failed the timing
improvement objective (36.03 MHz unplaced estimate) and is not deployable
acceptance evidence for this repair.

## Architectural rule and reproduction

The PDF skill guided text and visual inspection of Intel 241430-004, printed
7-26–7-28 and 25-122–25-125
([local manual](../../../ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf)).
FPREM/FPREM1 produce exact remainders and do not newly raise PE. Nevertheless,
with **UM=0**, a nonzero tiny result raises UE even when exact; a stack result
is multiplied by `2^24576`. With UM=1, an exact tiny remainder does not raise UE.
An unmasked operand exception takes priority and preserves the operands.

Minimal example, either remainder instruction:

```
CW = 006f                         # UM=0, other exceptions masked, PC24
A  = 0001:8000000000000001
B  = 0001:8000000000000000

Expected ST0 = 5fc2:8000000000000000, UE/ES/B set, no newly raised PE
Unfixed  ST0 = 0000:0000000000000001, UE/ES/B absent
```

Both normal operands are valid; this case does not depend on a denormal input,
save-state workaround, application behavior or reference condition-code policy.
FRSTOR/FNSAVE in the fixture only create and inspect a single-instruction test.

## Closed diagnostic

`underflow_vectors.py` computes results using integer arithmetic in minimum-x80
subnormal units. It covers all 63 normalization shifts; cancellation, nearest
quotient sign reversal, zero results, tiny and pseudo-denormal inputs, normal
controls, both instructions, UM/DM combinations, PC24/53/64, four RC settings,
signs, three TOP positions and old masked sticky flags. PC/RC are fully crossed;
sign/TOP/sticky-state variants are directed combinations, not a full Cartesian
product. Every case completes in one remainder instruction.

Evidence: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/underflow-state-r2`.

| Implementation | Cases | Defined-state failures | Result |
|---|---:|---:|---|
| Native host x87 | 7,104 | 0 | Independent oracle agrees |
| Current private QEMU `b81831c8…` | 7,104 | 3,216 | All unmasked tiny-result cases |
| Current shared FPU `b8b49226…` | 7,104 | 3,216 | All unmasked tiny-result cases |

All other cases pass, including masked tiny results and unmasked denormal
operand aborts. The checker verifies control/status, physical tags and **all
eight x80 payloads**, not just ST0. Undefined condition bits on operand abort
and numeric underflow are excluded from this local architectural oracle and
retained as raw observations. Complete nonfaulting quotient bits are checked.
There is no change to the repository trace comparator or its masks. Observed
underflow quotient-condition distributions happen to agree across all three
implementations; that agreement is not the basis of the UE/value finding.

R1 incorrectly required a particular operand-abort C2 value, producing 168
native-only status mismatches. That assumption was removed to match the
existing operand-exception oracle's treatment of undefined condition bits.
The original run is retained under `underflow-state-r1`, along with
`underflow_vectors-original.py`, SHA-256
`7f3857a077619727c212484b65074d6cafd8c85255e2b6f78bfac0502d6d2e0b`.
Its original receipt is untouched; the archived bytes preserve its historical
source identity after the working oracle was corrected. R2 is a fresh run.

R2 owner `ventium-fprem-underflow-state-oct15-r2.service`, invocation
`596244083e8f4b6cb12b9e93f785290a`, closes exit 0 / MainPID 0. That exit reports
**diagnostic completion**, not an implementation pass; both failed verdicts
are explicit in `closed.json`. Peak RAM is 114,544,640 bytes. Actual native
affinity is CPU12 for all three binaries, with recorded argv/cgroup/starttime
and actual wait/reaping. The RTL run takes about 2.4 seconds and retains the
existing command-poisoning and three in-flight-reset checks. No compiler ran
alongside Vivado. The tested shared FPU/SRT source hashes exactly match the
frozen FPGA candidate; this is still a leaf test, not whole-core acceptance.

## Proposed repair and required verification

The private-reference recipe `prepare_underflow.py` inserts a single block in
`helper_fprem_common`: after successful arithmetic, detect a true nonzero tiny
result with UM=0, scale it by `2^24576` while precision remains extended, and
raise UE. Place the block **before** the operand-abort `done` label, so aborted
IE/DE cases cannot rescale the preserved input. Zero, pseudo-normal, NaN and
infinite results are excluded. No global SoftFloat policy changes. Eight host
tests pass across the exact integer oracle, mutation rejection and recipe;
the subsequent compiled reference and instruction tests are recorded below.
`build_underflow.py` retains the bounded fresh builder and refuses a concurrent
Vivado family; do not bypass that check to start it during synthesis.

For RTL, prefer carrying the accepted underflow mask into the existing shared
SRT remainder service. In `ST_RNORM`, the normalized significand and signed
exponent already exist: UM=0 should add 24576 to a nonzero tiny result's
exponent, set the existing result UE bit, and retain exact significand/quotient
information. The two zero-quotient bypasses also need the response; neither may
silently return an unscaled tiny A. At the architectural shell, merge UE only
when no higher-priority operand abort occurred; commit the scaled result and
derive ES/B normally. Do not suppress destination writeback for this result
exception as is done for operand exceptions.

Avoid introducing another general 64-bit normalizer at the top-level writeback
mux when the shared engine already has one. Any interface change must cover
every caller and nonshared-profile status path explicitly. Preserve divide,
sqrt, reset/cancel behavior, ordinary remainder latency and UV-fast acceptance.
The diagnostic and private-reference recipe do not change RTL. A separate
exact-parent experiment now exists in
[`prepare_remainder_underflow.py`](../../srt/prepare_remainder_underflow.py):
it latches accepted UM, reuses `ST_RNORM` for both tiny-A bypasses, packs the
scaled exponent and UE, and merges UE below operand-exception priority. Both
`ST_SPECIAL` and `ST_RNORM` respond on the following engine clock, so the bypass
does not add a stage. Divide/sqrt and the remainder recurrence are unchanged.
One explicit tie-off preserves the nonshared caller's previous behavior;
**legacy unmasked-underflow support is not repaired or claimed**. Before any
production promotion, all standalone engine callers also require explicit
port integration and regression tests.

The bounded runner adds a 758-case engine test (all normalization shifts,
accepted-UM poisoning, both bypasses and reset, plus two following divide/sqrt
controls), the 7,104-case underflow
matrix, the existing 9,552 operand cases and 576 infinite-divisor cases. It
requires the retained bad control to fail and checks unchanged leaf latencies.
Four additional host recipe/oracle tests pass. This experiment does not mutate
the FPGA freeze or production sources.

## Closed shared-FPU repair tests

Evidence: `srt-underflow-r2` and `build-underflow-r1` under the same external
evidence root. The fresh private reference changes exactly one of 11,132 source
files; its build closes in 29.75 seconds with unchanged pins. QEMU binary:
`998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85`.
The repository's canonical QEMU is untouched.

| Matrix | Cases | Native / repaired QEMU / repaired RTL failures | Unfixed RTL failures |
|---|---:|---:|---:|
| Exact tiny-result/mask/precision/rounding matrix | 7,104 | 0 / 0 / 0 | 3,216 |
| Earlier operand-exception and complete-stack matrix | 9,552 | 0 / 0 / 0 | 0 |
| Infinite-divisor bypass, signed zero and pseudo-normal controls | 576 | 0 / 0 / 0 | 72 |

All **17,232 architectural cases** retain exactly the control's measured leaf
latency. The separate engine test passes 758 remainder operations, in-flight
reset and two following divide/sqrt controls. It deliberately changes UM,
operands, mode, rounding/precision and start while a remainder is in flight.
The architectural test also checks response UE and rejects spurious OE/PE.
No new comparison mask or change to ordinary recurrence/rounding is involved.
Twelve host tests pass across the existing oracle/reference tests and new
recipe/infinite-divisor mutation checks.

The guarded 32-job leaf build and tests close in 13.21 seconds, native exit 0,
with unchanged source pins. Owner `ventium-fprem-underflow-rtl-oct15-r2.service`,
invocation `5c78150da5fd4f2e86d6c5af93e8ad8f`, is terminal (MainPID 0). Every
native child has exact argv, actual CPU12 affinity, cgroup/start-time evidence
and actual wait/reaping. No Vivado overlapped these builds. Shared-FPU binary:
`899139eaff1daa55ba00ed3cfc9003614775b36bebbea8c89f303f8544ab623b`.
Repaired SRT source: `480f5f23d9c151ce6ca0df243e449c2446e435a1c556308c359d3cc652742fd2`;
shared top: `0cdf1129c030bcd2b21e73400fafe20cb6192cad5376358c90f7e52c7a0e796c`.

Two failed launch/test attempts are retained, not relabelled as passes. QEMU
launcher R1 omitted the build guard's `--` separator and started no compiler;
launcher R2 owns the successful build. RTL run R1 passed the engine and 7,104
underflow cases, then its process observer sampled an empty `/proc/.../cmdline`
during a short native probe's exit. R2 supplies native probe input only after
observing exact executable/argv/affinity, so it does not rely on scheduling or
accept missing identity evidence. R1's original runner is archived alongside
its unchanged failed receipt as `run_remainder_underflow-original.py`, hash
`c50841a761835c05e3b416380117c464f464227abe1b760cc2c6fd62282a35ea`.

The repaired private QEMU also passes all **7,488 numeric sequences / 216,768
records**, including 209,280 partial steps, plus **96 following-FADD precision
restoration cases**. The retained pre-repair reference fails 96,868 sequence
checks; native x87 and the new reference both have zero mismatches. Evidence:
`regressions-underflow-r1`, owner
`ventium-fprem-underflow-regression-oct15-r1.service`, invocation
`d201e6d91ce240688dd212b240a4bc37`, terminal exit 0 / MainPID 0, 190.75 seconds,
unchanged source pins. These older sequence vectors exercise masked underflow;
they are not coverage of unmasked partial-result exception delivery.

Remaining verification includes partial reductions on the repaired RTL,
unmasked partial-result handling, whole-core UV-fast UE delivery, all standalone
SRT caller profiles, canonical gates and the standard suite. The unchanged
canonical functional gate remains **7 PASS / 101 FAIL** from the parent audit;
private-reference results do not turn it green. Final
FPGA timing and physical Quake/Win95 acceptance must use the repaired source
set; the current synthesis cannot qualify a later underflow repair.

Gameplay baseline remains **0.50520554 total U+V IPC**, model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
**5,600,065,237–5,700,065,237**. It predates the candidate. Candidate gameplay,
underflow-repair area and timing effects are unmeasured.
