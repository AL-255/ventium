# Early prime-width payload — 2026-10-16

Status: **private experiment; extracted-source tests, whole-core compilation
and private-reference checks pass; canonical gate remains FAIL**. All eight
directed child corpora pass; their historical aggregate counter check fails.
Independent complete same-input A/B regrading finds no candidate difference.
No production RTL, board image,
constraints, goldens or comparator policy has changed. No frequency or
gameplay gain is claimed.

## Structural issue and proposed fix

The [interior fetch-size experiment](../fe_pipe/SFETCH_INTERIOR_COFACTOR.md)
reduced LUTs but regressed matched **unplaced** frequency from 36.968577 to
34.481570 MHz. Its worst path traversed frontend alignment/decode, pairing,
`mc_prime_v_branch`, checked descriptor width, extent/segment checks,
`mc_prepare_ok`, next-request control and D-cache LRU. These are not routed
frequencies or measured board clocks.

The existing early `mc_address_payload` already selects the correct ordinary
V, held V, FP-self or branch-successor producer. The width still came from the
later checked descriptor, unnecessarily serializing its validation before
extent arithmetic. [The exact-parent recipe](prepare_prime_width_payload.py)
uses the early payload's `w8` and `fp_sti[0]` for that arithmetic and its `w8`
for the live-prime strobe. Checked descriptor validity still gates admission.

Only six field references change in `rtl/core/core_mem_chain.svh`: five in
preparation eligibility and one in the strobe expression. Retained-request
width, AGI/reference priority, request/commit equations, source selection,
decoder, state registers and pipeline stages are unchanged. FP64 self-prime
remains denied; this does not add support for a new fast form. No bubbles,
pairing suppression, forced unsafe issue or workload-specific cases are added.

The experiment starts from the faster **boundary-stage parent**, not the
interior-fetch or next-ready timing regressions. Simulation-only assertions
compare full preparation eligibility every post-reset edge, byte enables on
every actual offer, and early/checked width identity for valid memory/FP
descriptors. These assertions are absent under synthesis.

## Closed evidence

All generated evidence is under
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

| Check | Result |
| --- | --- |
| Source-extracted selection/strobe tests | 65,536 samples each in legacy and residency-span profiles; both pass |
| Negative controls | Dropping held/FP/branch ownership or forcing byte/dword width each fails |
| Host/source/build/driver/audit guards | 8 tests pass |
| Private whole-core build | Native exit0 in 19.84 seconds |
| Fresh qualified-private-reference corpus | 108 pass, 80,800 records, 30,132 actual V retirements |
| Canonical `make verify` | **FAIL**: 7 functional PASS / 101 FAIL; nine failed cycle bands |
| Complete canonical cycle A/B | All 20 streams / 66,807 records identical to the parent |
| Eight directed child corpora | All pass; complete architectural/cycle comparisons retained |
| Historical aggregate counter gate | **FAIL**; three totals differ from its older baseline |
| Independent same-input A/B audit | 4,240 complete stream pairs and all nine probe counters identical |

The leaf covers ordinary V, held V, FP-self, branch successors, byte/dword
strobes, denied descriptors, FP64 rejection and AGI/reference override
priority. In the residency-span profile it observes 16,202 width checks,
28,361 strobe checks and 8,192 FP64 denials; the legacy profile observes
16,179 / 28,338 / 8,192. Returned-byte ownership is an abstract mask, not a
cache model. This is bounded native testing, not whole-core formal proof.

Leaf owner `ventium-prime-width-leaf-oct16-r1.service`, invocation
`d96d5a1ad91343fe85ad117297713d09`, closed exit0 / MainPID0 in 7.56 seconds.
Native children used CPUs 18–21 and were waited/reaped; peak memory was
33,808,384 bytes, no OOM. Evidence: `prime-width-leaf-r1`.

Build owner `ventium-prime-width-build-oct16-r1.service`, invocation
`1c4200026812480ba82ee10af4f22c4d`, closed exit0 / MainPID0. All **195 source
files** and **153 definitions** are audited; only the header above changes.
The existing exclusive 32-job, 10 GiB RAM / 2 GiB swap build guard and fatal
structural-warning policy remain. The uniquely named native harness object
binds to this model's generated header; no external VPATH object is reused.

The fresh private-reference run closed exit0 / MainPID0 in **107.20 seconds**.
[Independent regrading](audit_prime_width_func.py) checks 12,379 input pins,
native CPU4–7 execution, executable-image identity and full architectural
records. All 108 pass under existing manifest policy; 105 pass without optional
masks. `tx_regform`, `tx_regform2` and `tx_stack` still require their pre-existing
x87 stack-fault masks. The qualified private reference has **not** replaced
canonical QEMU. Peak memory: 143,384,576 bytes; no OOM.

That run is `prime-width-func-r2`, owner
`ventium-prime-width-func-oct16-r2.service`, invocation
`0de7ee0501a14641a0abfce2b579faa6`. The first launch (`r1`, invocation
`b28de0bbdef949df88f5e669e8b981c5`) failed before program execution because
the canonical job inventory did not yet exist. Its failed driver and native
closure are retained. The retry began only after the inventory existed; no
checker or RTL was changed to make it pass.

Canonical owner `ventium-prime-width-verify-oct16-r1.service`, invocation
`2a41905e43f74a2daef7d65dfa26e273`, closed native exit2 / controller exit1
after **387.77 seconds**. The gate's unchanged policy forces one worker even
when four are requested. It uses real AXI latency 7/7, `--cycle-func --l1-axi`
for functional cases and `--l1-axi` for cycle cases. All source pins remain
unchanged. Its failure is not waived by private-reference results.

The retained failure inventory finds 101 terminal-length mismatches: 90
length-only and 11 with FSW C1 as the first field difference. A separate strict
canonical A/B architectural check **fails**: only one of 108 streams is
identical. All other streams first differ at record zero in ESP (and two each
also in EBP/ESI); these independent canonical runs use different initial stack
addresses (`0x40800030` versus `0x40800050`). Do not mask those fields or call
this an identical-input comparison. Same-input directed A/B is separate.
Evidence: `prime-width-canonical-inventory-r1.json` and
`prime-width-canonical-ab-r1.json`.

## Directed checks and remaining work

[The eight-corpus driver](run_prime_width_core.py) preserves the original
load/store, held-V, branch, integer, FP, AGI, reference-prime and AGI-store
fixtures, QEMU comparisons, exact full-state/cycle A/B and coverage thresholds.
It runs under the exclusive parallel-test guard; native children remain
bounded by each original driver's limits. Any historical coverage-count drift
is a failure to investigate, not an automatically adjusted expectation.
Evidence: `prime-width-core-checks-r1`, owner
`ventium-prime-width-core-checks-oct16-r1.service`, invocation
`c53eb9d385a0472faf4de153b2b0980c`; native scope invocation
`8309e8d067bc4c7ba048fe1816700c82`. It closes controller exit1 / MainPID0 in
**263.36 seconds**; the native scope is inactive. All eight child processes
return exit0, all inputs remain unchanged, and all 4,240 probe records are
present. The final aggregate fails its original historical count assertion:

| Probe total | Historical expectation | Actual parent | Candidate |
| --- | ---: | ---: | ---: |
| Clocks | 21,190,336 | 16,951,320 | 16,951,320 |
| Reference-prime | 24,352 | 22,872 | 22,872 |
| Prime | 282,808 | 132,736 | 132,736 |

All six other counters match both the historical totals and the current
parent. The original failed receipt and assertion are unchanged. An
[independent diagnostic audit](audit_prime_width_core.py) checks **43,232
input/artifact pins**, closed native ownership, native exit codes and actual
UV-fast/AXI commands. It reparses every complete parent/candidate trace and
every probe counter: **641,832 architectural records, 641,832 cycle records,
163,956 actual V retirements**, with **0% incremental cycle change**. No
record, state field or counter is masked. The count difference predates this
candidate; it is not a new lost-prime regression or a measured speedup from
the width change. Receipt: `prime-width-core-checks-r1/parent-equivalence-audit.json`.
That diagnostic explicitly retains `legacy_aggregate_gate_passed=false` and
`canonical_gate_passed=false`; it does not relabel either failed gate.

The audit's first reader attempt stopped before producing a verdict because
the AGI/reference drivers name their exit-code field `exit`, while the other
JSON drivers use `native_exit`. The reader now checks each original schema
explicitly. Host tests reject altered counters, missing/duplicate probe
records, malformed exit receipts and changed/truncated architectural traces.
No native test rerun or acceptance-policy change was needed.

Before promotion: qualify the aggregate expectations for this exact parent
without weakening individual comparisons, transfer the exact source delta to the
full-PC and hardware profiles, repeat cold correctness/input controls, and
measure matched synthesis/timing. Retain the faster parent if timing regresses.
The canonical gate repair, duration-valid CoreMark score, standard suite and
matching physical Win95/UI plus full Quake timedemo remain open. There is no
new bitstream or FPGA pass for this experiment.

## Identities and gameplay baseline

- Parent core model: `e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a`.
- Candidate core model: `be6b6973e9ac6dcaf14f262e854deaeaad4248e7d3ff5d82569068dd756b37e8`.
- Parent header: `3615d9ea4bf93e8c3e08958a1459b111f2bff692822d988d24ec9045f05787ca`.
- Candidate header: `2871ad8a6739d4c88c1296d843d5de8e285603d876289b638cc8c5ee47ecec73`.
- Qualified private reference: `998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85`.

Latest verified gameplay is **0.51045343 total U+V IPC**, cycles
**1,200,065,247–1,300,065,247**, on model
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`:
39,242,072 U and 11,803,271 V retirements / 100 million clocks. U-only IPC is
0.39242072. This predates the boundary, input and prime-width candidates.
The current candidate has **no gameplay IPC measurement**. Different scene
windows do not establish an incremental fix gain, and neither that window nor
these directed tests establish timedemo completion.
