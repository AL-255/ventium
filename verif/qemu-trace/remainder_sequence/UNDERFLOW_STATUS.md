# Exact FPREM underflow — October 15, 2026

**Confirmed RTL and private-reference defect; repair not yet qualified.**
The FPGA synthesis currently running contains the earlier numeric and
operand-exception fixes, but not this newly isolated underflow fix. It remains
a timing experiment, not a deployable acceptance result.

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
Current  ST0 = 0000:0000000000000001, UE/ES/B absent
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
the new reference has **not** been compiled or instruction-tested yet.
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
This RTL repair is **not implemented** by the diagnostic or reference recipe.

Next verification must include the new 7,104-case matrix with retained bad
controls, the earlier 9,552 operand cases and 7,488 numeric sequences, following
FADD precision restoration, special/infinite divisors, partial reductions,
whole-core UV-fast UE delivery, canonical gates and the standard suite. Final
FPGA timing and physical Quake/Win95 acceptance must use the repaired source
set; the current synthesis cannot qualify a later underflow repair.

Gameplay baseline remains **0.50520554 total U+V IPC**, model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
**5,600,065,237–5,700,065,237**. It predates the candidate. Candidate gameplay,
underflow-repair area and timing effects are unmeasured.
