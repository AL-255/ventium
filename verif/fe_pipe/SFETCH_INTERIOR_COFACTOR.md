# Interior fetch-size output cofactor — 2026-10-16

Status: **private experiment; leaf/boundary/interior/private-functional checks
passed, canonical gate still FAIL; timing unmeasured**.
No production RTL, FPGA bitstream, timing constraints, cycle bands or reference
goldens were changed. No frequency/performance gain is established.

## Why this experiment

The [next-ready experiment](../l1/NEXT_READY_COFACTOR.md) reduced LUT use by
0.36% but **regressed** the matched unplaced frequency estimate from 36.968577
to 34.947928 MHz. Its worst 96-level path still traverses `d_fetch_need`,
`sfetch_want_size`, extent/routing, pair credit and ACK into GPR writeback.
Neither estimate is routed sign-off or measured hardware frequency.

The boundary-only stage already registers exact boundary sizes; its interior
arm selects `sfetch_want_size`. That producer first replaces the decoder count
with four whenever `sfetch_interior16` is true, then clips at the page end.
Consequently the selected interior arm cannot depend on the decoder count:

```
want = page_clip(interior ? 4 : decoded_remaining)
old_size = interior ? want : registered_boundary_size
new_size = interior ? page_clip(4) : registered_boundary_size
```

[The exact-source recipe](prepare_sfetch_interior_cofactor.py) makes this
cofactor explicit. It does **not** replace the result with a constant four:
`ffd/ffe/fff` still select `3/2/1`, even for otherwise unreachable input
combinations. Request generation, decoder, stage ownership, page-walk hold,
fault/header priority, reset, acknowledgment and byte-count updates are
unchanged. A non-synthesis assertion compares the **entire size payload every
post-reset clock**, not merely successful requests. The non-interior16 profile
keeps its original registered result.

The new model deliberately starts from the faster boundary-stage parent,
**not** the next-ready derivative. Only `rtl/core/core.sv` differs in the
195-source closure; all 153 definitions, assertion/error-class flags and
real-AXI model parameters are retained. There are no new stages, bubbles,
disabled pairing paths or workload-specific conditions.

## Evidence

Root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

| Check | Result |
| --- | --- |
| Source-extracted default-profile output miter | 196,608 comparisons pass |
| Source-extracted interior16-profile output miter | 196,608 comparisons pass |
| Negative controls | Missing page clip, wrong interior width and raw boundary width each fail |
| Binary symbolic proof | Equivalence `unsat`; non-vacuity and all three mutants `sat` |
| Host/source/build guard tests | 4 pass |
| Private whole-core compile | Exit0, 20.11 seconds, exact private harness/header binding |
| Original 22 fetch-boundary guests, both AXI delays | Pass: full QEMU state plus exact A/B state/cycle comparison |
| Fresh 108-program qualified-private-reference check | 108 pass; 80,800 records / 30,132 actual V retires; not canonical reference promotion |
| Original interior-fetch corpus, 48 cases / delays 0 and 7 | 192 measurements pass; independent complete-trace regrade finds 0% cycle delta |
| Unchanged canonical `make verify` | **FAIL**, native exit2; 7 functional PASS / 101 FAIL; all 20 cycle streams parent-identical |

The miter covers all 4,096 page offsets, both mux arms and all eight registered
size values, plus every pair of five-bit decoder/valid-byte counts at the last
eight page offsets. The symbolic proof covers **all** binary combinations of
these input widths, including count wrap and invalid stage sizes. It is a
combinational identity proof, not whole-core formal verification or an
unrestricted X/Z-control equivalence claim.

Leaf owner `ventium-sfetch-interior-leaf-oct16-r1.service`, invocation
`566a89d5c3a149cdb5c61a0a207c5a21`, closed exit0 / MainPID0 in **0.747 seconds**.
Actual child affinity was CPUs 18–19, all children waited/reaped, peak memory
**34,332,672 bytes**, no swap/OOM. Inputs, generated source, compiled images,
native logs, mutants and proof are retained in `sfetch-interior-leaf-r1`.
The core builder independently rechecked those artifacts and native closure.

Core build owner `ventium-sfetch-interior-build-oct16-r1.service`, invocation
`5aa9ac6d576046c99fcabb0a3e9c7aba`, used the unchanged exclusive 32-job guard,
10 GiB RAM / 2 GiB swap build scope and 600-second native deadline. Inputs
remained unchanged and the freshly named harness object uses this model's
generated header. No Vivado instance overlapped compilation.

The original boundary driver closed exit0 / MainPID0 in **24.50 seconds**:
**21,832 candidate records, 4,968 actual V retirements**, all inputs unchanged.
It ran 176 RTL and 88 native QEMU processes across the 22 original guests and
AXI delays 0/7, preserving complete state/cycle comparisons and all fault
witnesses. No stepping, snapshot, U-only fallback or pairing suppression was
substituted for the original workloads. Evidence: `sfetch-interior-boundary-r1`.

The fresh private-reference run closed in **107.94 seconds**; independent
[regrading](audit_sfetch_interior_func.py) checked **12,367 input pins**, actual
CPU4–7 native execution, complete architectural records and executable-image
identity. All 108 pass under the existing manifest policy; 105 also pass without
optional masks. `tx_regform`, `tx_regform2` and `tx_stack` still require the
**pre-existing** x87 stack-fault masks. The qualified private reference
`998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85`
has not replaced canonical QEMU. Peak memory: **161,189,888 bytes**.

The unchanged canonical gate closed in **391.43 seconds**, native exit2
(controller exit1). Its 7/101 functional verdict and nine failed cycle bands
remain failures; all 20 full cycle streams are parent-identical. No mask,
golden, band, comparison or guest was relaxed. This experiment is **not** a
canonical-gate repair or a standard-suite pass.

The original interior-fetch driver ran after that gate released the exclusive
guard: 32 queued workers, bounded eight concurrent native children, **5.14
seconds**, no OOM/process-limit event, all children reaped. Independent
[cycle regrading](audit_sfetch_interior_demand.py) checks **192 complete A/B
stream pairs** and all per-case clocks, hot intervals, warm loops and AXI
activity: exactly equal. Candidate cycle traces contain **15,200 records and
384 actual V retirements**, with **0% incremental cycle change**. Peak memory:
**363,503,616 bytes**. Neither these retire counts nor short-loop CPI is a
gameplay measurement. Evidence: `sfetch-interior-demand-r1/cycle-audit.json`.

Identities:

- Parent core model: `e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a`.
- Parent `core.sv`: `8d454c1ce275963da75354aca703701a4341b441031ae53f39e1fb911a365d0d`.
- Changed `core.sv`: `1a9ca5a3e883889dc121c8ae8380f30a01377b8f3681261cc4c1f7fe6160b104`.
- Candidate core model: `ffada6de537cbc101a255845d3094d5eb32fd642306c718734484217d3d7cc5a`.
- Core directory: `sfetch-interior-core-r1`.
- Boundary owner: `ventium-sfetch-interior-boundary-oct16-r1.service`, invocation `2509e3b6d2d949a0bd692e89eb28f889`.
- Canonical owner: `ventium-sfetch-interior-verify-oct16-r1.service`, invocation `f4249836e9c74e9ea5e7c37d339e5859`.
- Private functional owner: `ventium-sfetch-interior-func-oct16-r1.service`, invocation `553fc166e7a14ecca03db6b35ebb8b23`.
- Interior-fetch owner: `ventium-sfetch-interior-demand-oct16-r1.service`, invocation `64ac56cac3e7471eabe6a39f71065484`; native scope `a434ecaf2e974b59ab23cc8ded5e2ac7`.

## Remaining qualification

The bounded whole-core comparisons above are complete; they are not exhaustive
correctness proof. Next require exact source transfer, short CoreMark controls,
matched synthesis/path analysis, then routed 40 MHz closure. Mapping
may reshare logic; a cleaner expression is not evidence of faster hardware.
The canonical gate, complete standard suite, and matching physical-board Win95
cold desktop/input and complete Quake timedemo remain mandatory.

Candidate gameplay IPC is **unmeasured**. Latest audited older baseline:
**0.49046518 total U+V**, model
`7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68`,
cycles **1,600,065,247–1,700,065,247**. U-only IPC is 0.37998050; the remaining
0.11048468 is V retirement. This baseline predates the V-result/input/fetch
candidates and is neither full timedemo completion nor FPGA acceptance.
