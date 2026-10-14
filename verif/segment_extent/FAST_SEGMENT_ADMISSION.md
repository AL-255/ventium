# Parallel fast-memory segment admission

October 14, 2026 UTC. **Private timing candidate, not promoted or installed.**
Directed checks pass with unchanged sampled architectural state, clocks and V
retirements. The canonical gate remains **7 functional PASS / 101 FAIL**.
There is no new frequency or gameplay result.

## Why and what

The [way-bank/fetch-page parent](../../fpga/WAY_BANKED_EXPORT.md) closes at
**34.495843251 MHz synthesized/unplaced**, below 40 MHz. Its worst EIP-to-ESP
path has 100 logic levels and 28.778 ns data delay, through `sys_fp_load_ok3`,
`fp_sys_bail`, fast-store admission, translation/router logic, queue readiness,
cache acknowledgement and writeback. The previous fetch-overlength path is
no longer the reported worst path. Unplaced interconnect estimates are not
routed congestion evidence.

`prepare_fast_segment.py` changes only the fast-load admission block in
`rtl/core/core.sv`:

- Reduce normal-data attributes and full-limit eligibility for all descriptors
  in parallel, then select one eligibility bit with the unchanged segment ID.
- The bounded branch already requires DS; read its constant DS descriptor
  directly, removing the late segment mux from the limit comparison.
- Preserve strict earlier-page admission, byte/word/dword boundaries, protected
  descriptor-load/non-null checks, expand-down rejection, common mode guards,
  the separate store-page filter and debugger fallback.

No register, extra cycle, timing exception, cache reduction, disabled UV path,
guest patch or new feature define is introduced. The store-address adder and
downstream request/acknowledgement chain remain unchanged; this rewrite does
not claim to eliminate the entire remaining critical path.

## Closed verification

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

| Check | Result |
| --- | --- |
| Recipe | Three tests PASS: exact reversal, constant bounded inputs, drift/reapplication rejection |
| Symbolic cofactor | UNSAT for differing load/store/bail results; all two-state descriptors/addresses/width codes, legal indices 0–5 and feature combinations |
| Actual SV expressions | 300,704 comparisons each in full, flat-only, load-only and disabled profiles: **1,202,816 total** |
| Negative controls | Wrong DS/SS, ignored expand-down, inclusive page comparison and wrong word boundary: all four SAT symbolically and rejected in native SV |
| Private-reference corpus | 108 PASS / 80,800 complete records; 105 unmasked, three with existing x87 masks |
| Identical-input replay | 216 native executions; all 108 complete traces, clocks and **30,132 V retirements** identical |
| Canonical `make verify` | **FAIL**, native make exit 2; 7 functional PASS / 101 FAIL; all 20 cycle traces equal parent |
| Cold system controls | Five fixtures × AXI delays 0/7/31 × two models: **30 executions**, identical parent/candidate state and clocks |

The symbolic/SV leaves abstract the unchanged width/decode producers; this is
not a sequential whole-processor proof. No canonical failure or existing x87
mask is waived. The independent regression audit regrades full records and
rechecks **19,399 input pins**.

Cold fixtures are original `psysfpbounded`, `psysfpload`, `psysfpreloc`,
`pfaststore` and `pfaststack_segenf`, rebuilt outside the checkout. Every run
uses UV-fast/AXI, has observed native child affinity and exits with guest PASS
status 133. There are **24 complete-state QEMU comparisons**. The six invalid-SS
runs use the existing precise #SS/#PF frame/register/memory witnesses because
QEMU does not provide a trustworthy segment-limit oracle.

Candidate system traces contain **30,141 records and 5,487 V retirements**, with
nonzero L1 backing acknowledgements. At every delay, logged memory-admission
bails are 192 for bounded DS, 1 for the crossing store, 2 for invalid SS and 0
for normal DS/SS and relocated controls. The runner grades full-state equality,
exact A/B counters and fault witnesses; compiling defines alone is not evidence
of fast-path exercise.

Two failed harness attempts are retained: the first leaf launch omitted the
build wrapper's `--` and stopped before creating outputs; `fast-segment-system-r1`
incorrectly required an optional default-quiesce banner. Corrected system `r2`
requires actual backing traffic and guest exit status, without a post-exit idle
interval. Neither retry changed RTL or fixtures. Failed receipts are not passes.

## Identity and full-PC transfer

- Parent core: `139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7`.
- New core: `1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c`.
- New `core.sv`: `238cd9f713cc6e84a6881cb5e06b8ff341a90cb428be8882b1f1b2d974491ac4`.

`build_fast_segment_core.py` preserves the 195-file closure, changing only
`core.sv`, all 152 defines, assertions and `AXI_LINE_REPLAY=0`. Its guarded
32-job, 10 GiB RAM / 2 GiB swap build closes in **20.52 s**, with unchanged
inputs and a private harness object compiled against its own generated header.
Dirty root RTL and the frozen parent are untouched.

`fpga/build_fast_segment_soc.py` transfers that exact one-file delta to the
full PC: all **102 shared RTL files** match the tested core, preserving 156
defines, full P5 caches, single-fill and posted-16 transport. The guarded
build closes in **23.69 s**, model
`93315731b334cfe12ced52ba1dda186907480a30584e56bb7389d5f3bc123924`.
Inputs and the private generated-header contract are checked. The **98 existing
platform structural warnings are unchanged**, not a full-SoC lint pass.

| Receipt | SHA-256 |
| --- | --- |
| `fast-segment-leaf-r1/closed.json` | `35e92836a1b51fc4c259833104873e07e982412c84c9ec45ffb56d1c2a3d097e` |
| `fast-segment-core-r1/build-closed.json` | `060b6c494b3df15899b07f3a5ae4836fb75ac399b99813d8b8591649432072ba` |
| `fast-segment-system-r2/closed.json` | `a30de9aeb360b8c276037fa561bd2c147f996eceef313a62071afcb439dffcf9` |
| `fast-segment-regression-audit.json` | `efcc3318f5c3af9a5926da23a206af9e06f9edbe5c321769564efff4c0e37232` |

## Still required

This candidate remains **UNQUALIFIED**. Next are full-PC controls and a
source-matched timing measurement; no new Vivado build or programming occurred
in this step. A >=40 MHz synthesized result, routed timing, green canonical
gates, duration-valid CoreMark score, complete standard suite and physical
UV-fast Win95 UI/Quake timedemo acceptance are still required.

Latest verified gameplay baseline: **0.50607097 total U+V IPC**, older
`c7b95b78` FP-repair simulation, cycles **1,300,065,237–1,400,065,237**.
This candidate is gameplay-unmeasured. The unchanged installed FPGA still has
no Doom FPS result.
