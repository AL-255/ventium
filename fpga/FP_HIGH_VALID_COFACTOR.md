# Wide FP response qualification — October 12

**Private candidate built; leaf/cache checks pass. Whole-core verification is
running. No new Fmax, standard-suite or physical FPGA acceptance.** The target
remains **at least 40 MHz post-synthesis Fmax**, UV+fast, full P5 caches.

The [paired-read experiment](PAIR_NOW_READ_COMPLETION.md) regresses from
30.676729 to 29.953572 MHz. All 30 worst reported paths traverse next-read
lookup, read/code ACK qualification and wide FP validity before the FPU bank
clock enable (113 logic levels). The best parent checkpoint is retained.
This experiment continues from the paired-read candidate to cut that newly
measured dependency; it is not a claim that the isolated paired-read change
improved timing. Compare eventual timing against the best parent too.

## Change and safety boundary

The [exact-source recipe](../verif/l1/prepare_fp_high_valid_cofactor.py) changes
three files in a new private derivative, never an existing frozen export:

- `ven_l1d.sv`: qualify high-word validity with existing current-address tag
  results and primary/shadow saved-line identities. Factor common residency,
  reset, cacheability, snoop, flush, stream, early-response and extent guards
  out of the reuse terms. The complete read owner already implies the read ACK.
  Under these guards, lookahead exclusion is exactly
  `!(c_next_req && rd_match)`; idle priming requires `!c_req` and cannot apply.
- `ventium_l1_axi.sv`: remove the duplicate local ACK check from high-valid.
  Keep request/reset/access-denial/DMA-drain and whole-operand cacheability
  qualification. The L1 contract above still guarantees an acknowledged read.
- `core.sv`: use the guaranteed wide response without re-entering the ACK mux;
  retain final-fragment suppression, whole-page extent, debug, fault and owner
  checks. Factor command completion into ordinary acknowledged final beats OR
  an already-qualified wide take. Narrow and second-beat commands still require
  their original ACK. Nothing broadens their eligibility.

No feature flag, register, SRAM port, cache capacity, request, architectural
ACK, operand data or pipeline cycle is added/changed. All original response
equations remain as simulation assertions at each affected layer. Another
assertion checks the internal high-valid → acknowledged-read contract even
outside an FP consumer. No retirement masks, changed goldens or workload
special cases are introduced.

The mathematical argument is binary combinational equivalence under the
existing internal response contract, **not** arbitrary four-state equivalence
or a full-core temporal proof. Unsupported feature combinations retain their
existing elaboration failures. Sequential and ISA checks remain necessary.

## Closed checks

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

1. [Native source-extracted test](../verif/l1/test_fp_high_valid_cofactor.py),
   `fp-high-valid-leaf-r3`: **509,600 comparisons**, 45,128 valid high responses
   (27,148 primary / 17,980 shadow), 34,905 wide takes, plus narrow/second-beat
   commands and 20,873 excluded lookaheads. Five separately compiled mutations
   fail natively: lost next-owner exclusion, residency, full-line provenance,
   extent, and missing narrow-command ACK. Runtime **12.71 s**; invocation
   `7c28a348679c404e80a63cc120300509`. Earlier r1/r2 are retained failed test
   harness preparations (spacing extraction and declarations), not RTL passes.
2. [All-bit contract proof](../verif/l1/prove_fp_high_valid_cofactor.py),
   `fp-high-valid-proof-r1`: all four changed outputs are equivalent in the
   abstract binary model; local and seam high-valid both imply read ACK.
   All six counterexample queries are UNSAT; all five mutation queries are SAT.
   Addresses/offsets are bit-vectors, and registered ownership is unconstrained.
   Invocation `9cb9f423b80a415998f141472644f4d1`. The proof is paired with actual
   extracted-source simulation; it does not model reachability or execution.
3. [Full-profile cache miter](../verif/l1/run_fp_high_valid_cache.py),
   `fp-high-valid-cache-r1`: two actual 128-set, two-way banked caches receive
   identical public traffic. **737,677 both-edge comparisons** cover outputs,
   control state, all data banks, tags, valid bits and LRU. **66,339 valid high
   words** independently match backing memory, including all legal unaligned
   offsets, shadow/primary overlap, partial captured banks, line boundaries,
   invalidation and rejected lookahead. The lost-next-owner mutation fails
   natively. No internal state is forced. Runtime **16.38 s**; invocation
   `deb59f492e704bf49c446365d6510aa8`.
4. [Whole-core build](../verif/l1/build_fp_high_valid_core.py),
   `fp-high-valid-core-r1`: native zero in **20.68 s**, unchanged input pins,
   **195 files / 152 identical definitions**, exactly the three intended RTL
   deltas. The unique C++ harness has a local object and verified matching
   generated-header dependency. All six structural lint classes remain errors.
   Model SHA-256:
   `ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c`.
   Invocation `de2e514a391f4f35ade19aad4f4aafa3`.

## Work still required

The first unchanged full FP matrix, `fp-high-valid-fp-r1`, closes **FAIL** in
31.02 seconds: 32 concurrent fixtures exceed the fixed 128-task envelope when
QEMU starts its helper threads. Native logs show `EAGAIN`/failed QEMU startup;
308 measurements complete, but this is not a matrix pass. Invocation
`de716da6b8bc409db60ac12b75d9747b`. Its failed evidence is retained.

The complete matrix is queued again with **eight concurrent fixtures**, without
changing cases, comparisons, timeouts or RTL, under the same 16 GiB / 128-task
guard (`ventium-fp-high-valid-fp-r2-oct12`, invocation
`4de0443618f64fefb57e4d42582c53e8`). Compiler fan-out remains 32. The original
canonical `make verify` is currently running (`ventium-fp-high-valid-verify-oct12`,
invocation `e013e606f3be4d8baaa3b7b3b5d69bf4`); the matrix waits for its lock.
Do not treat launching either as passing.
The parent's **7 PASS / 101 FAIL** is an unwaived acceptance blocker.

Complete whole-core FP boundary/fault and integer/memory A/B checks, PC transfer,
CoreMark preflights and frozen lint before measuring this hardware candidate.
Then require >=40 MHz synthesized Fmax, routed closure and physical UV-fast
Windows 95 cold desktop/UI and original FreeDOS Quake full timedemo validation,
as well as the full standard suite and differential gates. No synthesis or
deployment of this derivative has been launched.

Gameplay baseline: **0.51030715 total U+V simulated retirement-event IPC**,
older build `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. This candidate
has no gameplay measurement; the baseline is not physical FPGA IPC.
