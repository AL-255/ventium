# Exact FPREM underflow — October 15, 2026

**Shared-FPU leaf and cold whole-core directed tests pass; canonical and FPGA
qualification remain open.**
The latest measured [combined hardware experiment](../../l1/BRANCH_ADDRESS_SHAPE.md)
does contain the numeric/operand/underflow repairs, but reaches only
**35.814 MHz synthesized/unplaced** and is not routed or deployed. Its profile
does not yet include the separately tested strict waiting-x87 policy below.
The [subsequent DECODE payload experiment](../../fetchguard/DECODE_BUS_PAYLOAD.md)
retains that policy: 72 delayed-exception cases pass with exact strict-parent
trace/cycle equality, and its source-matched PC/FPGA freeze includes the define.
That freeze has now passed native synthesis and its independent closure audit;
its clock audit is running. Synthesized frequency, routed timing and physical
board acceptance remain unqualified; see the linked experiment for live status.
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

## Cold whole-core integration, without the rejected timing experiment

`prepare_remainder_underflow_core.py` applies the same two tested FPU changes
to the retained pre-metadata core. The only core change is the explicit legacy
mask tie-off. All 195 source files were audited against that parent and the
leaf source closure; the rejected fetch-metadata change is not inherited.
The build retains all 152 defines, assertions, single-fill AXI and the private
model-specific C++ harness. No production RTL or frozen FPGA image is changed.

Evidence: `core-underflow-r1`, model
`77c0c895122a6d7c890924e4806af51d287cd64c5d2094aa9eaa8032079fab1d`,
parent model `2ac15c8ba4fd6fbfcfb2dccb0daa0bb41448e7756b6abd2b2e32b8a92684bc1e`.
The bounded 32-job build closes exit 0 in 19.96 seconds, with stable pins.
Controller `ventium-fprem-underflow-core-oct15-r2.service`, invocation
`9d82f40a1dbb4b0686115ade94776547`. Launcher R1 failed before compilation because
its preflight confused the leaf controller's invocation ID with the guarded
scope's distinct ID; the corrected check verifies both identities explicitly.

Three new cold assembly fixtures run with `cycle_mode=1`, `--cycle-func
--l1-axi`, AXI latency 7, native x87 self-checks, repaired-QEMU self-checks,
and complete QEMU/RTL architectural comparisons through the unchanged trace
tools. No trace truncation or new mask is used.

| Fixture | Repaired core records / V retirements | Retained parent |
|---|---:|---|
| Normal-operand cancellation, both instructions | 42 / 4 | Expected failure; wrong guest result |
| Both tiny-A bypasses and signed-zero control | 61 / 5 | Expected failure; wrong guest result |
| IE/DE precedence and preserved operand | 44 / 4 | Pass |

All **147 complete records and 13 V retirements** pass. Evidence:
`cold-underflow-r1`, terminal exit 0, 15.86 seconds, stable pins. These tests
check UE/status and the scaled result, clearing the pending exception before
the subsequent store. They do **not** yet qualify delayed `#MF` delivery.

Other closed checks on this exact whole-core model:

- `func-underflow-r1`: **108/108** private-reference functional tests pass,
  109.45 seconds. The existing optional-stack comparison policy is unchanged;
  this is not a claim of a newly strict stack comparison or canonical success.
- `system-underflow-r1`: bounded FP, fast FP loads, relocated FP, fast stores
  and invalid-SS stack controls at AXI latencies **0, 7 and 31**. All parent and
  candidate records/counts match: **30,141 candidate records, 5,487 V
  retirements**, 23.58 seconds. Four fixtures use complete system-QEMU diffs;
  invalid SS uses the retained Intel-spec fault witnesses. Fast-path execution
  and actual backing acknowledgements are checked, not inferred from defines.
- `core-underflow-r1/verify-closed.json`: unchanged canonical `make verify`
  **fails**, native make exit 2, **7 functional PASS / 101 FAIL**, 390.34 seconds.
  All **20 cycle RTL traces are record-identical to the parent**. Existing
  cycle-band failures also remain. Private-reference success does not turn
  this gate green; no masks, goldens or bands were changed.

These workers are closed, source pins remain stable, and no OOM was observed.
Two host tests also pass for exact-parent rebasing and reversible identity-only
functional/system driver adaptation.

## Partial-result underflow matrix

`partial_underflow_vectors.py` checks **2,880** partial reductions (exponent
gap at least 64) against exact integer arithmetic. It admits every partial
reduction width **N=32..63** allowed by the instruction, rather than requiring
native x87, QEMU and SRT to choose the same width. Every legal non-aborted
remainder in this matrix is nonzero and tiny. Cases include both instructions,
all supported PC/RC combinations, sign/TOP/sticky variants, 720 unmasked-UE
results, 1,440 unmasked-DE operand aborts and 720 masked-result controls.

Native x87, repaired QEMU and repaired shared RTL each have **zero failures**;
the unfixed RTL fails exactly the 720 unmasked-UE cases. All eight x80 payloads,
tags, control and defined status bits are checked; undefined exception CC bits
are excluded only by this local oracle. Its host test accepts every legal
partial result and rejects missing UE. Evidence `partial-underflow-r1`, owner
`ventium-fprem-underflow-partial-oct15-r1.service`, invocation
`ff1bb1ef2d7f4abd8c4207aae5a603f9`, terminal exit 0, stable pins. Existing
binaries were reused; no compiler or Vivado ran for this test.

## Closed masked multi-step RTL regression

`run_remainder_underflow_sequences.py` builds the retained and repaired SRT
engine in both split and unsplit operand-port configurations. The existing
sequence fixture and exact integer oracle are unchanged; the candidate fixture
only explicitly ties the new UM input high. Each of the four models passes
**8,448 complete sequences / 266,880 records**, including **258,432 partial
steps** and a maximum of **597 instructions** in one sequence. Every result,
quotient, exception output and cycle count is identical across all four files
(SHA-256 `7e286fdd9dba7d08a10c0d13096bafb4b56cda3f79fef61b13d09fe67fbaf883`).
No truncation, new oracle exception or latency tolerance was introduced.

Evidence: `sequences-underflow-r1`, controller
`ventium-fprem-underflow-sequences-oct15-r1.service`, invocation
`115cc57193a54e12bca33a76f6210c44`, terminal exit 0 / MainPID 0. The guarded
build/run/grade sequence closes in **341.02 seconds**, stable source pins,
actual simulator CPU12 affinity and explicit child reaping. This verifies both
engine port configurations, not every standalone caller or whole-core profile.

## Cold delayed exception delivery and a remaining architectural gap

[`run_underflow_delivery.py`](../../srt/run_underflow_delivery.py) adds eight
cold protected-mode BIOS fixtures: normal cancellation, tiny finite/infinite
divisor bypass and partial reduction, each for FPREM and FPREM1. Each runs with
an immediately following FWAIT, FNOP or FLD1, at AXI delays 0/7/31, on the old
underflow-bad model and both repaired cores. No snapshot, single stepping,
interposed status read or guest workaround is used. The fixtures check saved
fault EIP, CR0.TS/EM handling, `#NM` before `#MF`, exactly-once retry, UE/ES/B
without PE, the scaled ST0 payload, preserved ST1 and final TOP. Partial
remainders accept every architecturally permitted reduction width.

| Model | Immediate FWAIT | Immediate FNOP | Immediate FLD1 |
|---|---:|---:|---:|
| Old underflow-bad `2ac15c8b…` | 0/24 | 0/24 | 0/24 |
| Underflow repair `77c0c895…` | 24/24 | 24/24 | **0/24** |
| Address-shape candidate `6deb3e92…` | 24/24 | 24/24 | **0/24** |

Both repaired models have identical complete architectural traces, cycle and
V-retirement counts for all cases. The latest candidate produces 137,544
architectural records and 39,984 V retirements across its 72 executions.
Every FLD1 failure exits at guest check `0x21`: two earlier #NM cases passed,
but the required #MF count is zero. This is **not a passing suite or a waived
expected failure**. FWAIT/FNOP delivery is qualified by these tests; delivery
at arbitrary waiting x87 instructions is not.

The cause is explicit configuration: `VEN_X87_MF_STRICT` is absent from all
152-definition tested cores. `core_fetch_decode.svh` otherwise checks pending
ES only for FWAIT/FNOP, and `core.sv`'s fast-FP trap fallback also omits ES.
Those two existing strict-mode arms must be qualified together; merely fixing
the slow decoder would leave the fast bypass unsafe. The proposed minimal
repair is to enable that existing architectural mode, retaining no-wait
status/clear instructions and normal UV-fast execution. It adds no blanket
FP/integer serialization. Its timing and performance effects are not assumed.

[`build_strict_mf_core.py`](../../sys/build_strict_mf_core.py) prepares a private
153-definition derivative with **all 195 source files unchanged** and a unique
native harness. Its guarded compiler refuses concurrent Vivado. The strict
replay retains the same fixtures, verdicts, native lifecycle and source pins;
only model selection and the now-inapplicable old/new equality check differ.
Two fixture tests, two configuration tests and one replay-adaptation test pass.
The subsequent derivative build and directed checks are closed below; physical
acceptance and canonical success are still not established.

Evidence `delivery-underflow-r1`, owner
`ventium-underflow-delivery-oct15-r1.service`, invocation
`4981932d8e07483893ec2fc8e71cd3c7`, closes **exit 1**, MainPID 0, in 95.19 seconds.
All 216 native executions were waited/reaped, source pins stayed unchanged,
actual CPU12 affinity and AXI activity were observed. Peak RAM was 474,796,032
bytes. The diagnostic completed but candidate acceptance is explicitly false.
This is an Intel-spec self-check, not a system-QEMU differential pass.

### Strict-mode derivative: closed directed repair

The unchanged 195-source model, with only `VEN_X87_MF_STRICT` added, builds in
**20.96 seconds** with a model-local harness object/header and stable input
pins. Binary SHA-256:
`08be10a26af0eb36e9393837bebca22b1eed186ad3020179f438143cb4fa8605`.
The controller is `ventium-strict-mf-core-oct15-r1.service`, invocation
`d90453b96f0b4b0fa0dc85f44f54e16e`, terminal exit 0 / MainPID 0. No compiler
overlapped Vivado: synthesis exited before this build, and the read-only
clock-audit family started only after the compiler exited.

- **72/72 delivery cases pass**, including all 24 formerly failing immediate
  FLD1 cases. FWAIT/FNOP retain 24/24 each. The exact same generated fixtures
  check 141,648 architectural records and 40,248 V retirements in 38.84 seconds.
  Source pins, actual CPU12 affinity and native wait/reaping are retained.
- **108/108 private-reference functional programs pass**, using the existing
  comparison policy, in 142.95 seconds. This is not a stricter stack comparison
  or a canonical-QEMU pass.
- **Five cold system controls at AXI delays 0/7/31 pass**, in 23.04 seconds:
  30,141 candidate records and 5,487 V retirements. Complete records and cycle
  counts match the nonstrict parent. This is measured absence of cycle
  regression in these controls, not a blanket performance claim.

All three owners are terminal exit 0 / MainPID 0: respectively
`ventium-strict-mf-delivery-oct15-r1.service` / `0451bfc5528b497c885af605c6ff0a45`,
`ventium-strict-mf-func-oct15-r1.service` / `e3c540e33081401589e7f17a8ed08cfd`, and
`ventium-strict-mf-system-oct15-r1.service` / `c6dad931d4e1454f80fd7b175bd6876e`.
Their evidence directories are `strict-mf-delivery-r1`, `strict-mf-func-r1`
and `strict-mf-system-r1` under the same root. No comparison mask, golden,
timing band, snapshot or pairing-disable control changed. The new worker
adapter's exact-reversal test also passes.

The unchanged canonical gate closes **FAIL**, native make exit 2, in
**387.20 seconds**: **7 functional PASS / 101 FAIL**, and all 20 RTL cycle
streams remain record-identical to the parent. Existing timing-band failures
remain. Source pins are stable; no masks, goldens or bands changed. Owner
`ventium-strict-mf-verify-oct15-r2.service`, invocation
`9d1275c4de7247bea741c1396d3d813e`, is terminal MainPID 0 / controller exit 1,
preserving that failed verdict. R1 was canceled **before any gate started**:
its outer timeout would have counted the clock-audit lock wait against the
verification budget. The canceled log/receipt remain under
`strict-mf-core-r1/verify-r1-canceled-before-gate`; no result is attributed to
that launcher and no timeout was relaxed. R2 began after the clock family
closed. The private-reference passes do not waive the canonical failure.

The fix currently exists only in the private model's build configuration.
It is **not yet transferred to a full-PC model or FPGA image**. The three
waiting instructions above do not exhaust every waiting/no-wait opcode,
fault-priority combination or memory-fault interaction.

Remaining verification includes broader strict-mode coverage, all
standalone SRT caller profiles, canonical gates and the standard suite.
Final FPGA timing and
physical Quake/Win95 acceptance must use the repaired source set; the older
synthesis cannot qualify a later underflow repair.

Gameplay baseline remains **0.50520554 total U+V IPC**, model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
**5,600,065,237–5,700,065,237**. It predates the candidate. Candidate gameplay
and isolated underflow-repair area/timing effects are unmeasured; the combined
hardware result above does not isolate this repair's contribution.
