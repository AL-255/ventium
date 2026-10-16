# Next-read readiness cofactor — October 16, 2026

Private timing experiment, **not promoted or deployed**. This removes one
request-dependent hit-selection dependency from L1 next-read readiness. It
adds no register, cache port or cycle. Timing and gameplay gain are unmeasured.
The parent is the [36.968577 MHz unplaced boundary-stage
experiment](../fe_pipe/SFETCH_BOUNDARY_STAGE.md), still below the required
40 MHz; neither number is routed sign-off.

## Exact change and invariant

[Recipe](prepare_next_ready_cofactor.py) accepts only L1 source SHA-256
`62d3332d4d044efe022acce33eaa99b16e9a36da7a43e4afeda0b0265baeb3f3`.
Candidate SHA-256:
`0429ad9d8f4f16f8534dc3d24321ae7d0cd4420680b74170de786a78703ac337`.
Only `rtl/mem/ven_l1d.sv` changes in the 195-source directed-core closure.

Let R be `c_next_req`, O/P the old-response/prime slot predicates with R
factored out, C current cacheability, H the next-address tag hit, and G the
unchanged next-cacheability, flush/snoop exclusion and access-shape checks.
The original readiness is:

```text
lookup = R && (O || P)
ready  = lookup && ((R && P) || C) && G && (lookup ? H : current_hit)
```

The replacement is exactly:

```text
ready = R && (P || (O && C)) && G && H
```

The identity holds for arbitrary binary O/P predicates, not just reachable
cache states. Existing parallel tag reads supply H. Lookup address/strobe
selection, request/capture signals, cache storage, response ownership and all
sequential behavior remain unchanged. A non-synthesis assertion compares old
and new readiness after reset. No program/PC checks, snapshots, guest patches,
pairing suppression or global slow-mode fallback are introduced.

## Closed evidence

Evidence root:
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

| Check | Result |
|---|---|
| Source-extracted equations, five profiles | 983,040 comparisons; three broken variants rejected |
| Boolean proof | Z3: equivalence UNSAT; ready witness and all three mutant counterexamples SAT |
| Actual full P5 cache, LUTRAM and register tags | 590,084 sampled edges; public outputs, capture controls and cache arrays match |
| Actual next-read priming under held data fills | 640 cases; all eight held beats, byte/dword positions, unchanged backing owner |
| Original 22 fetch/fault guests | 176 RTL executions, 88 QEMU comparisons, 21,832 candidate records, 4,968 V retirements |
| Paged/relocated load/store matrix | 288 measurements, 32,112 candidate records, 456 actual paired memory retirements |
| Integer/store matrix | 1,024 measurements, 169,472 candidate records, 512 V retirements; all 512 cycle deltas zero |
| Fresh qualified private-reference functional corpus | 108 passes under existing masks; 80,800 records, 30,132 V retirements |
| Same corpus without optional masks | 105 passes; existing `tx_regform`, `tx_regform2`, `tx_stack` failures remain |
| Canonical `make verify` | **FAIL: 7 functional PASS / 101 FAIL**, native make exit2 |
| Complete canonical cycle streams versus parent | All 20 identical; this is not a cycle-band pass |

The [independent local audit](audit_next_ready_cofactor.py) regenerates the
source-extracted equations and full-cache fixtures, replays Z3, checks complete
boundary traces against QEMU and the parent, verifies all 195 sources and the
private harness dependency, and rechecks 860 input pins. It distinguishes the
outer service IDs from the guarded inner scopes: exact scope lifecycle journal
events must fall inside their specific successful outer invocations.

The [independent functional audit](audit_next_ready_func.py) regrades all
80,800 records, checks actual child affinities/native exits and 12,418 input
pins, and verifies the executable images against the canonical run. Only GCC's
non-loadable randomized file-symbol strings may differ. Private oracle
`998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85`
is **not** promoted over canonical QEMU. No golden, mask or cycle band changes.

Directed model:
`274f36c65682611be280de39a536cb3fbdb39c22b1d5143ceadfe06f1f457ed5`;
parent `e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a`.
Both retain all 153 build definitions, assertions, full caches, relocated
UV-fast execution and real AXI (`--cycle-func --l1-axi` and
`--cycle --l1-axi`, latency0/7). Private model-specific C++ object and generated
header dependency are checked. Build: 19.90 seconds, 32 guarded compiler jobs.
Canonical run: 392.80 seconds; private functional run: 107.79 seconds.
Load/store and integer matrices: 18.30 and 42.08 seconds.

Full-cache retained controls also cover 150 chained accesses, 448 fresh pairs,
64 same-bank rejections, 1,536 held-pair checks, 640 data-under-instruction-fill
completions per tag configuration, and code-word reuse. Prime-under-I-fill
completions remain zero because the target intentionally does not enable that
option; do not report them as exercised. These sampled tests and the abstract
Boolean proof are not whole-cache arbitrary-state formal verification.

Failed attempts remain distinct: leaf R1 did not kill the missing-cacheability
mutant; R2 adds exhaustive readiness-decision enumeration. Cache R1 failed
compilation because its inherited fixture named an absent old parameter.
Cache R2 caught the mutant at the earlier public-ready miter, but the runner
incorrectly required the later stimulus assertion. R3 accepts only either of
those specific readiness failures. The final positive RTL is unchanged by
these test-harness corrections. No failed attempt is counted as a pass.

Four recipe/fixture/builder unit tests and three full-PC transfer guard tests
pass. The [full-PC transfer builder](../../fpga/build_next_ready_soc.py)
preserves all 102 shared processor/FP sources and the 157-definition posted-16
PC profile; only the L1 cofactor may differ. Its current build/short CoreMark
and later FPGA transfer/timing remain separate evidence, not acceptance.

## Still open

Matched synthesis/routed timing, full standard suite, canonical failure repair,
candidate FPGA Win95 cold desktop plus keyboard/mouse interaction, and a full
candidate FPGA Quake timedemo remain required. The boundary-stage parent's
measured boundary-fetch costs are inherited, not repaired by this cofactor.

Candidate gameplay IPC is **unmeasured**. Last verified older baseline:
**0.49046518 total U+V IPC**, model
`7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68`,
cycles **1,600,065,247–1,700,065,247**. That is 37,998,050 U plus 11,048,468 V
retirements in 100 million clocks; U-only IPC is 0.37998050. It predates the
V-result/input/fetch/readiness candidates and is not full timedemo completion
or physical FPGA performance.
