# No-memory hint coherence cofactor

Private two-header derivative of MC-LOCAL-COMMIT. **Not production RTL,
whole-core qualification, timing closure or FPGA acceptance.** Immediate
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

## Required next checks

Build a new complete-core derivative retaining the existing local-commit
change, UV-fast defines and all old-equation witnesses. Run canonical,
AGI/reference, held-store, paired-store, REP/SMC early-invalidation and
fault/interrupt comparisons; preserve complete architectural/cycle traces.
Then qualify full-PC behavior before a source-matched synthesis timing test.
Do not claim gain before measurement. The standard suite and physical FPGA
Win95/Quake acceptance remain required; canonical failures remain unwaived.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**; predates this proposal and is not FPGA IPC.
