# Unreachable retained storage in cache-only priming — October 16, 2026

**Private candidate; not promoted, timed, routed or deployed.** The extracted
state tests, guarded whole-core build and fresh private-reference corpus pass.
Canonical verification remains **FAIL**. All eight directed native corpora pass
and independently match the current parent; their old aggregate assertion fails.
No frequency, area or gameplay gain is claimed yet.

## Evidence for the structural problem

The faster [boundary-stage parent](../fe_pipe/SFETCH_BOUNDARY_STAGE.md) has a
**36.968577 MHz unplaced estimate**, below 40 MHz. Its 92-level worst setup
path ends at `pipe_mem_active_q`, through `mc_next_ready`, `mc_any_accept`,
`mc_chain_accept` and the pairing/owner mux. The native primitive inventory
still contains **487 FDRE instances** named for the retained successor's ten
state objects, including three `mc_valid_q` instances. These are observed
parent-netlist objects, not measured candidate savings or exclusive cone area.

This build defines `VEN_RAW_V_READ_PRIME`. In that existing mode, cache hints
warm an L1 window but never become retained architectural successor packets:

```text
RAW preparation implies mc_prime_base
retained capture requires mc_prepare_ok && !mc_prime_base
therefore retained capture is always false
reset initializes all retained state to zero
all other assignments clear valid or hold the existing state
```

The original source already asserts that RAW execution never retains an owner,
yet leaves the complete sequential implementation for the mapper to simplify.
The critical path and register inventory show that simplification did not
fully happen in the matched synthesis.

## Exact specialization

[`prepare_raw_prime_storage.py`](prepare_raw_prime_storage.py) changes only
`rtl/core/core_mem_chain.svh`. Under the **existing** RAW define it assigns the
ten unreachable state objects their reset zeros. Non-RAW builds retain the
entire original sequential block byte-for-byte. Simulation additionally runs
that original block with private witness registers and asserts their complete
state remains zero after reset. A future change that makes retained capture
reachable therefore fails visibly instead of silently losing a request.

The live AGI, reference, ordinary V, held V, branch-successor and FP hint
equations are untouched, as are request/commit/ready, decoder, exception,
fragment, paired-store and ordinary U/V admission equations. No hint or safe
pair is disabled; no bubble, new stage, new build flag, timing exception,
snapshot dependency or workload-specific condition is added.

- Parent header: `3615d9ea4bf93e8c3e08958a1459b111f2bff692822d988d24ec9045f05787ca`.
- Candidate header: `89cad588b5e5e27674399591b8c150610533c1eed1495689b057f3ec5e8147af`.
- Parent directed model: `e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a`.
- Candidate directed model: `41f99bcff8125a2caa7fe768f03f242bed1a43323e4d3a190109167248a34e9b`.

## Closed local evidence

Root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

[`run_raw_prime_storage.py`](run_raw_prime_storage.py) extracts the original
storage block and actual `fpd_t` declaration. Each positive profile compares
all **556 state bits for 16,385 edges**, enumerating every 13-bit control
combination twice with changing nonzero descriptor payloads. RAW sees 3,072
preparation samples and zero retained owners. The non-RAW control sees 6,144
preparations and 18 valid-owner observations. Both see 8,193 reset edges.
This is a bounded extracted-state test, not whole-core formal proof.

All four negative cases fail: omitted RAW preparation guard, inverted capture
guard, wrong specialized constant, and accidentally disabled non-RAW capture.
The first two are contract-negative controls; the latter two mutate the
candidate specialization. The source guard is hash-pinned and rejects drift.
Z3 proves the zero-state induction under that source-checked prepare implication
(`unsat`) and finds positive preparation and both broken-guard witnesses
(`sat`). Other eligibility conjuncts are abstracted; no full-core formal claim.

Leaf owner `ventium-raw-prime-storage-leaf-oct16-r1.service`, invocation
`4c0b8bfc54b1490c9f1f1fb7aa19fb92`, closes exit0 / MainPID0 in **10.58 s**,
peak memory **30,089,216 bytes**, no OOM. All six native children close and are
reaped on CPUs18–21. Evidence: `raw-prime-storage-leaf-r1`.

[`build_raw_prime_storage_core.py`](build_raw_prime_storage_core.py) independently
regenerates the leaf fixtures, replays the solver and checks its exact closed
owner before compiling. All **195 source files / 153 definitions** are checked;
only the header above changes. The exclusive 32-job build retains assertions,
fatal structural warnings, full caches, UV/relocated fast paths and the original
10 GiB RAM / 2 GiB swap cap. Its fresh private harness object uses this model's
generated header. Native build closes exit0 / MainPID0 in **19.87 seconds**
with unchanged pins, owner `ventium-raw-prime-storage-core-oct16-r1.service`,
invocation `84b43587f7744888b1ae9d4011a4da0e`. Evidence:
`raw-prime-storage-core-r1`. Seven recipe/build/driver host tests pass.

The fresh private-reference corpus closes exit0 / MainPID0 in **107.68 s**,
owner `ventium-raw-prime-storage-func-oct16-r1.service`, invocation
`214d8095cce7497c8cd458593cc6a4fc`. The independent audit checks **12,370
input pins**, complete **80,800 records**, **30,132 actual V retirements**,
native CPUs4–7 and unchanged executable images. All 108 pass under existing
manifest policy; 105 pass with optional masks removed. The same three historic
x87 stack-fault cases (`tx_regform`, `tx_regform2`, `tx_stack`) remain masked
failures, not newly repaired instructions. Peak memory is 153,571,328 bytes,
no OOM. Evidence: `raw-prime-storage-func-r1/audit.json`. Private oracle
`998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85` is not
promoted over canonical QEMU. The first audit attempt ran before canonical
ELFs existed and stopped without a verdict; after that job closed, the same
audit passed without a native rerun or policy change.

## Closed whole-core checks and remaining acceptance

The unchanged canonical `make verify` uses actual AXI 7/7,
`--cycle-func --l1-axi` and `--l1-axi` cycle jobs. Its parent has known canonical
failures; they are not waived by local or private-reference tests. It closes
native make exit2 / controller exit1 / MainPID0 in **387.12 seconds**, retaining
**7 functional PASS / 101 FAIL** and nine failed cycle bands. All **20 complete
cycle streams / 66,807 records** match the selected boundary parent exactly;
that is not a cycle-band pass. Inputs remain unchanged; no masks, goldens,
instruction caps or bands were changed. Owner
`ventium-raw-prime-storage-verify-oct16-r1.service`, invocation
`a3705f2c1e504774915472f3fb9a2d83`. Evidence: `raw-prime-storage-core-r1/verify-closed.json`.

The eight original QEMU/full-architectural/cycle corpora ran through
the same exclusive guard: load/store, held V, branch, integer, FP, AGI,
reference and AGI/store. All eight native children exit0 in **259.81 s**,
but the original historical aggregate assertion closes controller exit1,
MainPID0. Owner
`ventium-raw-prime-storage-core-checks-oct16-r1.service`, invocation
`febd335ce935488f8ae109377d4f86c7`; native scope invocation
`1bb8eb4df8ed4070b282ad380fe6c64b`. Their original historical aggregate count
assertion is retained; it already differs from the selected parent's counts.

[`audit_raw_prime_storage_core.py`](audit_raw_prime_storage_core.py) independently
checks **43,224 input pins**, exact closed owner/invocations, original commands,
**4,240 complete stream pairs**, **641,832 architectural records and 641,832
cycle records**, and **163,956 actual V retirements**. Every current-parent /
candidate stream and all nine probe totals match. No records are truncated and
no masks or acceptance bands change. Evidence:
`raw-prime-storage-core-checks-r1/audit.json`.

The three historical aggregate differences are clocks 21,190,336 versus
16,951,320; reference hints 24,352 versus 22,872; and primes 282,808 versus
132,736. The second value in each pair is identical for the selected parent and
candidate, not a gain from this specialization. Both observe zero retained
owners. The remaining six aggregate fields are unchanged. The audit explicitly
retains `legacy_aggregate_gate_passed=false` and `canonical_gate_passed=false`;
same-input equivalence is not a standard-suite pass.

Full-PC transfer must use the now-qualified boundary/input composition, not
revive rejected prime-width/interior/readiness experiments or drop the input
repair. Matched synthesis/routing to at least 40 MHz, canonical repair,
duration-valid CoreMark, the complete standard suite and matching physical
FPGA Win95 cold desktop/UI and full Quake timedemo remain required.

Latest verified gameplay baseline is **0.50229051 total U+V IPC**, model
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`, cycles
**1,400,065,247–1,500,065,247**. This is 38,787,572 U plus 11,441,479 V
retirements; U-only IPC is 0.38787572. It predates this candidate, which has
**no gameplay measurement**. Evidence is the independently checked
`v-result-carry-gameplay-window-1400-1500M-oct16-r1.json`; it is not timedemo
completion or physical-board acceptance.
