# No-memory hint coherence cofactor

Private two-header derivative of MC-LOCAL-COMMIT. **Not production RTL,
completed qualification, timing closure or FPGA acceptance.** Immediate
target remains at least **40 MHz synthesized Fmax in UV + fast mode**.
Latest measured predecessor is **32.270556344 MHz**, not a pass.

## Why this change

The measured critical path traverses paired-store admission, live own-store
I-cache snoop hits, REP recovery and public `mem_next_commit`, reaching L1D
replacement state at **−5.581 ns**. Local pipeline-commit factoring alone
does not remove this public AGI/reference hint path.

`prepare_prime_coherence_cut.py` changes only the AGI and reference hint
commit equations. Its source audit pins eight complete files (core, chain,
both hint headers, bus driver, L1 seam, I-cache and top-level wiring):

1. Both hints require `pipe_prime_live_arm`: S_PIPE, no held integer memory
   owner, and `pipe_agi || fp_sys_bail`. Both new U requests require the
   negation of both those latter signals, so neither request can coexist.
2. A paired V store requires a U request. The S_PIPE bus driver can assert
   write direction only for a U store. The fragment engine is excluded by
   the hints' `mc_boundary_ok` offer guard. Thus no current own-store snoop
   source remains, including the paired V store and crossing-line copy.
3. In the audited integration, I-cache ports 1/2 are **current CPU stores**,
   not asynchronous snoops or write-queue-drain notifications. External/DMA
   invalidation is port 0. Own-cache and bypass hit terms require ports 1/2.
4. REP `take` implies REP `hold`, which already blocks the shared live arm.

Under those contracts, only the hint's recovery test can omit live own-store
hits. It retains **prior sticky poison, redecode state, global flush and
external invalidation**. No actual I-cache invalidation, REP sequencer,
architectural memory/commit equation, clock, mode, pipeline stage or port is
changed. All other hint guards remain. Simulation assertions compare each
new commit with its original equation and check the no-memory/no-own-snoop
condition before hint acceptance, independently of cache readiness.

This relies on the integration contract: arbitrarily injecting asynchronous
events on own-store ports 1/2 is not covered. A differently wired caller needs
its own audit, not silent adoption of this optimization.

## Native leaf evidence and limits

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.
`prime-coherence-leaf-r2` passed **1,048,576 Boolean combinations** in
**9.368 seconds**, with **1,920 AGI / 1,920 reference commits**, **2,304 sticky
poison blocks / 2,304 external invalidation blocks**, and **61,440 current
paired-store cases** outside the no-memory hint window.

The actual old/new hint equations and live-arm equation are source-extracted.
Request/SMC fan-in is a source-audited Boolean abstraction, **not a formal or
sequential proof of the whole processor**. The abstraction deliberately permits
external invalidation during offers to exercise the retained local guard.
Three native negative controls detect removal of sticky poison, removal of
external invalidation, and violation of the no-memory ownership contract.
The first two produce output mismatches; the third fires the ownership check.

Service `ventium-prime-coherence-leaf-r2-oct13`, invocation
`fb0cee21809e42288b28b7529c77c374`, is terminal, exit 0, stable pins.
Closure SHA-256:
`a1e91cdc11803949751235552f36ded6e16af12399753d138f8fdf1a6621a866`.
Derivative header SHA-256 values:

- AGI: `2fe36debf81b73a11d0c03efce591518a5260ccf0067833406bfb81586c926ab`
- Reference: `20c28f6aba142ba4893a3aa5cd8e1203e1b9c3d925f5ad8c3ce48ffd005fac8c`

The preceding `prime-coherence-leaf-r1` is a **failed runner**, not a pass:
its deliberately broken owner triggered the ownership assertion before the
runner's expected output-mismatch marker. Its logs and failed receipt remain;
the runner now checks that specific negative control's correct marker. The
positive equations and coverage were unchanged. An earlier source-audit dry
run also caught the harness choosing S_LOAD in the preceding segment-identity
case; extraction now searches after the bus S_PIPE arm.

## Full-core build and canonical result

`prime-coherence-core-r1` built in **20.172 seconds**, preserving all **195
parent source files / 152 UV-fast defines** except the two audited headers.
The previous local-commit change is retained. Assertions and the unique C++
harness/generated-header dependency check remain enabled. Model SHA-256:
`ea3cde2721fd7af43bd4efdeaf8cbe154b803ff74a989a5660588233966b9c6b`.
Build owner `ventium-prime-coherence-core-oct13`, invocation
`9651483e7350494394033c8021cdd628`, closed with exit 0 and stable pins.
Build closure SHA-256:
`10c95f17735dbc928e98ae43327ab836a31f7ec623e626e4b9dd524db58f13b4`.

The unchanged canonical gate closed in **392.309 seconds**, native `make`
exit **2**: **7 functional PASS / 101 FAIL**, still a failed gate. All **20
complete cycle streams** equal the FP-WIDE-CONTEXT predecessor (before both
new commit cofactors). No golden, comparison mask or cycle band changed.
Service `ventium-prime-coherence-verify-oct13`, invocation
`8da0112e08e046bb9f3bf76fe2b4ae50`, is terminal with controller exit 1.
Canonical closure SHA-256:
`3cb00e344ca04b408ccdd1bfd3a5841100b530d065a801cefa1a146716fe9bac`.
This is not a canonical correctness pass or a waiver of existing failures.

## New cold REP-SMC → hint handoff test

`run_prime_coherence_smc.py` reuses the existing protected-mode bypass SMC
fixture, adds a cached variant and follows both with ordinary AGI/reference
loads. It boots from reset; no snapshot or direct-bus control is used. Every
run uses **UV-fast and the actual AXI backend**, measured AXI read activity,
complete QEMU architectural comparison, and complete parent/candidate cycle
comparison. Delays are 0, 7 and 31 AXI clocks, in both cycle and cycle-functional
observation modes. Both models reach real ISA debug-exit 133 without faults.

`prime-coherence-smc-r1` passed **24 runs in 3.156 seconds**. Each candidate
cycle run had **6 paired V retirements / 5 AGI hints / 6 reference hints**,
with a drained, non-overlapping AXI stream. Full state/cycle records equal the
MC-local parent; these are directed-test counters, not gameplay IPC.

The two stores modify unused bytes in the active executable line, so matching
architectural state alone would not prove refetch. Independent checker
`audit_prime_coherence_smc.py` additionally verified **48 decode episodes**:
the second REP decode observes `d3c45b6a` in the first modified dword while the
next dword is still zero. All bypass runs show a bypass-only own-store hit
with neither valid I-cache way hit. No unsafe REP continuation arm/boundary
appears. **24 checker-negative controls** replacing the recovered bytes with
stale bytes are rejected. This closes a relevant new cold interaction test;
it is not full system or physical FPGA acceptance.

SMC owner `ventium-prime-coherence-smc-oct13`, invocation
`3face772c7684276988382d94ad71082`, closed with exit 0 and stable pins.
Native closure SHA-256:
`cbaf7f1518156c7d6a39ed1737f419aa1321f855a8c1b7fa199e76f3d7dc8970`.
Independent audit SHA-256:
`d4dad785a5a7541a8b503aa5d7ae695186f31b298247ac86101b5e7369198891`.

## Eight-corpus full-core comparison

`prime-coherence-corpora-r1` passed in **300.442 seconds**: all **4,240
probes / 21,190,336 clocks** match the MC-local parent. The eight unchanged
corpora cover load/store, held reads, branches, integer, FP, AGI, reference
priming and AGI/store interaction. Coverage is unchanged: **18,172 AGI /
24,352 reference / 282,808 prime / 5,616 store intent / 3,072 request /
1,872 accept / 1,536 shape-only events**. Retained-owner events are zero in
this RAW profile; that disabled mode is not qualified by these runs.
Service `ventium-prime-coherence-corpora-oct13`, invocation
`405f39b75b64402fa83e1960bd2c2d98`, closed with exit 0 and stable pins.
Closure SHA-256:
`2a7b6a4facc28beb88e225167960ef184433294c3243562fd66f5663485a7e86`.

Three host tests also check build guards, both exact model identities, the
unchanged eight-corpus coverage assertions and unchanged extended-regression
plan. No parent equality is substituted for a passing canonical gate.

The complete wide-FP matrix, `prime-coherence-fp-r1`, also passed in **67.615
seconds**: **384 cold fixtures / 1,536 measurements / 768 parent/candidate
cycle comparisons**, all with zero cycle delta and complete architectural
comparisons retained. Service `ventium-prime-coherence-fullfp-oct13`, invocation
`3d8bad489b2e4ee29b472418f8ab3ef5`, is terminal with exit 0 and stable pins.
Closure SHA-256:
`758ed04e092707482b4c998880961119b3a6b090f7a5df9dc1940b4800e48930`.

## Disk preservation

After the native owners became terminal, two byte-verified, recoverable
archives reclaimed **1,271,622,357 logical bytes**. Sources, executable
models, headers, dependency files, receipts and all pinned inputs remain.

- `closed-prime-coherence-compiler.tar.gz`: 442 generated compiler products
  from the MC-local and prime-coherence models, **463,360,966 → 73,390,105
  bytes**. SHA-256 `ab99c7f781e7e5ac9a439e2227beb55551681c5a6840cce3c1b79518c8e94305`.
  Restore under `/home/yukidama/external/tmp`.
- `closed-prime-coherence-corpora.tar.gz`: 38,352 closed trace/log files,
  **969,279,506 → 87,628,010 bytes**. SHA-256
  `fdc81ea8316aa81b56ea0e0d76a83f63d4e78b6e5bd92b018d32477a2c34abac`.
  Restore under the evidence root named above.

Both archive plans, per-member hashes, verification and closure receipts are
retained in the evidence root. Native models were rehashed after compaction.

The completed full-FP text was subsequently re-compared (208,128 candidate
architectural records) and byte-verified into
`closed-prime-coherence-fp-text.tar.gz`: **11,916 files, 487,393,592 →
29,595,015 bytes**. SHA-256
`0081785dd3cc57ba2e146a1f46943bf002e409d46b01596ced308bad7218a678`.
Restore relative to `/home/yukidama/external/tmp`; inputs/receipts remain.

## Required next checks

Finish fault/interrupt/replay qualification. Preserve complete
architectural/cycle traces and all old-equation witnesses.
The unchanged 12-group extended plan is running as
`ventium-prime-coherence-regressions-oct13`, invocation
`21a2f62b70df4c37afd6abbc5aed3048`, output `prime-coherence-regressions-r1`.
Check its live owner and eventual closure before treating any group as passed;
do not restart based on an observation timeout. No synthesis is queued.
Then qualify full-PC behavior before a source-matched synthesis timing test.
Do not claim gain before measurement. The standard suite and physical FPGA
Win95/Quake acceptance remain required; canonical failures remain unwaived.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**; predates this proposal and is not FPGA IPC.
