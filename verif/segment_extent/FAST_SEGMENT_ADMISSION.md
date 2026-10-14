# Parallel fast-memory segment admission

October 14, 2026 UTC. **Private timing candidate, not promoted or installed.**
Directed checks pass with unchanged sampled architectural state, clocks and V
retirements. The canonical gate remains **7 functional PASS / 101 FAIL**.
Source-matched synthesis and independent timing audit close at **35.474830608
MHz unplaced**, up **2.84%** from the immediate parent but still below 40 MHz.
There is no candidate gameplay result or new bitstream.

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
| Original fetch-boundary controls | 22 fixtures, 176 native RTL executions, **88 full QEMU comparisons**; exact parent/candidate state and clocks |
| Original x87 environment-store faults/retries | 44 fixtures × AXI delays 0/7: **88 full QEMU comparisons**, unchanged images |
| Full-PC short CoreMark | Both 10-iteration CRC checks PASS; **4,767,218 / 4,753,406 ticks**, identical to parent |

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

The CoreMark closure audit checks **21,468 inputs**, both terminal/native
closures, original ROM/disks, actual CPU12 affinity and nonzero V retirements
(1,055,307 / 1,054,254). Both seeds remain too short for a valid score or full
standard-suite acceptance. **Measured throughput change is 0%.**

The fetch audit independently regrades the original witnesses and full traces:
21,832 candidate records, 4,968 V retirements and 44 probe observations. Its
18,131 input pins remain unchanged. This existing runner did not observe
per-child affinity; the outer taskset alone is not described as that evidence.
The environment-fault runner closed normally with no OOM and all 44 unchanged
fixtures passing at both delays; it is not a replacement for the still-red
canonical gate.

| Receipt | SHA-256 |
| --- | --- |
| `fast-segment-leaf-r1/closed.json` | `35e92836a1b51fc4c259833104873e07e982412c84c9ec45ffb56d1c2a3d097e` |
| `fast-segment-core-r1/build-closed.json` | `060b6c494b3df15899b07f3a5ae4836fb75ac399b99813d8b8591649432072ba` |
| `fast-segment-system-r2/closed.json` | `a30de9aeb360b8c276037fa561bd2c147f996eceef313a62071afcb439dffcf9` |
| `fast-segment-regression-audit.json` | `efcc3318f5c3af9a5926da23a206af9e06f9edbe5c321769564efff4c0e37232` |
| `fast-segment-fetch-r1/audit.json` | `4ed6e04dbe86cd85a956a1ee4cb11f73d26b77a725b87c3983a9b593a281b4a2` |
| `fast-segment-env-fault-r1/closed.json` | `f7c1d1d9f70d99426fa927553540288520e6023ca6e75de3d7263fc46915430f` |
| `fast-segment-soc-r1/coremark/audit.json` | `c67ad755f58c4ce7a84596da8e6521da50e06d04e0f6d2f0446378854b8d2e04` |

## Matched FPGA synthesis and timing closure

`fpga/freeze_fast_segment_rk_candidate.py` checks the exact one-file transfer
against the immediate way-banked parent. The freeze retains 190 payload files,
170 common HDL inputs, all 158 hardware defines, 40/100 MHz constraints,
full P5 caches, single-fill and posted-16 transport. Manifest SHA-256:
`d4122ecbed950b845654bec8060fa83b96213f07b373b002604704cea06b6f7e`.
Hardware-profile CPU-hierarchy lint passes all six hard structural classes;
this is not full-SoC lint. Four export tests and four controller tests pass,
including rejection of weakened clocks/disk guards.

The first synthesis controller, invocation
`c679e761a2984246b727bed8ba8beaba`, fails **before launching Vivado**. Although
free space exceeded 6 GiB, admission also requires twice the measured parent
growth above the 4 GiB stop floor: **7,208,493,056 bytes** total. That condition
was not met. `fast-segment-synthesis-r1/preflight-failed.json` and its journal
preserve the failed attempt; it is not a native synthesis result.

The subsequent cleanup removes exactly four unpinned PCH files and seven
PCH-only archives, **780,714,399 bytes**, after checking archive contents,
closed build owners, no open handles and **28,856 protected hashes**. Sources,
models, dependency/header evidence, media, traces and all DCPs remain. An archive
with a PCH-looking name also contained traces and was explicitly excluded.
Deleted cache copies are not recoverable, but are regenerable. The plan and
closure are `segment-compiler-cache-prune-{plan,closed}.json` in the evidence
root. Available space rose to 7.31 GB; no guard was weakened.

The separately named `fast-segment-synthesis-r2` starts at **03:45:21 UTC**,
owner `ventium-fast-segment-synth-oct14-r2.service`, invocation
`ceb137ea40374841945bf828d4ea8608`. Exactly the same sources/defines/mapper and
native guard/cleanup policy are used: one exclusive Vivado family, 45-minute
native limit, 8 GiB RAM / 6 GiB swap, 13 GiB combined early stop, 2 GiB host
reserve and 4 GiB free-disk stop. CPU16–19 is applied with actual `taskset`.
It closes normally at **04:16:33 UTC**, native exit 0, in **1,871.61 s**.
The independent audit checks **26,046 input pins**, native source/definition
records and the resulting DCP. Peak RAM is **8,589,762,560 bytes**, peak swap
**1,209,921,536 bytes**; no OOM, resource stop or input mutation occurs.
The native synthesis summary retains **1 critical warning and 1,561 warnings**;
native completion is not a warning-free or functional-acceptance claim.

The unchanged read-only clock/structure/parent-comparison Tcl runs only
after successful native closure and independent DCP/source audit. Its separate
8/4 GiB RAM/swap and 15-minute limits remain unchanged. The sequencer has no
retry, route, deployment or guard-relaxation path. It also records native Vivado
driver affinity. Prepared-r2 receipt SHA-256:
`bae01818fafee5f9d9c6e3cf4207fd6f59716a77bf18985708c9f45735db14fe`.
The original tested recipe is `fpga/prepare_fast_segment_synthesis.py`; the
identity-only retry and sequencing scripts are retained as
`prepare_fast_segment_retry.py` and `finish_fast_segment_timing.py` in the
external evidence root. No dirty root RTL was modified.

That timing owner, `ventium-fast-segment-clock-oct14-r2.service`, invocation
`b2fbc88b58e340afa4b78248d80133be`, closes at **04:24:32 UTC**, exit 0, in
**468.39 s**. Its independent audit checks **21,870 input pins**, the native
25 ns core / 10 ns PL clocks and exact parent DCP. Peak RAM is **4,924,215,296
bytes**, with no swap or OOM. Both retained owners have MainPID 0.

| Matched synthesized estimate | Way-banked parent | Fast-segment candidate |
| --- | ---: | ---: |
| Core Fmax, MHz | 34.495843251 | 35.474830608 |
| Setup slack at 40 MHz, ns | -3.989 | -3.189 |
| Worst data delay, ns | 28.778 | 27.978 |
| Worst logic levels | 100 | 98 |
| Whole-chip LUTs | 187,410 | 187,215 |
| Whole-chip registers | 55,006 | 54,993 |
| RAMB36-equivalent / DSP | 277.5 / 47 | 277.5 / 47 |

Fmax is `1000 / (25 - setup_slack)`, not the selected board clock. Candidate
hold slack is -0.101 ns. This is **synthesized, unplaced estimation**, not
routed timing or proof of physical congestion. The remaining worst path still
runs from EIP through fetch/decode, PREFIX66 length-dependent memory payload
selection, address/segment checks, request/ACK logic and ESP writeback. The
98-level path does not cross the shared-FP datapath. No timing exception,
pipeline disable or reduced cache is used to obtain this improvement.

Closure hashes under the same evidence root:

| Evidence | SHA-256 |
| --- | --- |
| `fast-segment-synthesis-r2/closed.json` | `f26a8cb120742d9519ff43fbd4cc9791b1ae7f25dba249930b0de7bf7e596e75` |
| `fast-segment-synthesis-r2/audit.json` | `6281be4c9804c760895a27a550793dae0e94b199131b30c5ec81eba083ff875d` |
| `fast-segment-clock-r2/closed.json` | `f75dc53754475b301a500d9625ca5e026aa03a0a76aafcca52039b3636e81402` |
| `fast-segment-clock-r2/audit.json` | `7618459c973d1bf62904a27a3ce7a2e36b9c90b6fbb3eafcc7d17c96f57b3cd1` |

## Still required

This candidate remains **UNQUALIFIED**. The short full-PC controls are closed;
source-matched synthesis is closed below target, with no new FPGA programming. A >=40 MHz
synthesized result, routed timing, green canonical
gates, duration-valid CoreMark score, complete standard suite and physical
UV-fast Win95 UI/Quake timedemo acceptance are still required.

Latest verified gameplay baseline: **0.47330821 total U+V IPC**, older
`c7b95b78` FP-repair simulation, cycles **1,500,065,237–1,600,065,237**.
This candidate is gameplay-unmeasured. The unchanged installed FPGA still has
no Doom FPS result.
