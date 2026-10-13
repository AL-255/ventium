# Local successor commit timing proposal

Private derivative of FP-WIDE-CONTEXT, **not production RTL or FPGA
acceptance**. Complete-core A/B passed; timing/gameplay remain unmeasured.

## Measured reason

FP-WIDE-CONTEXT closed at **32.270556344 MHz synthesized/unplaced estimate**,
setup −5.988 ns, worse than its matched PAYLOAD-REGION parent's
34.113392918 MHz. The 111-level worst path starts at `q_pc_reg[0]`, traverses
decode/extent, paired-store backing admission, the live own-store instruction
cache snoop, REP continuation recovery, and `mem_next_commit`, then reaches
`pipe_mem_store_pair_q`. Captured V's clear path likewise reaches −5.388 ns.
These are different from the parent's FP/capture-admission endpoints.

## Exact cofactor

The public hint port commits one of AGI, reference-only, or ordinary pipeline
successor hints. Existing `mc_chain_accept` and `mc_prime_accept` both use the
whole public OR, despite their own offer excluding AGI/reference ownership:

- `mc_offer` requires `mc_valid_q`; both AGI/reference selectors require its
  negation, and their offers/commits require those selectors.
- `mc_prime_offer` requires `mc_prepare_ok`, whose first assignment requires
  `!agi_prime_select && !ref_prime_select`. Its later system-mode assignments
  only restrict that value or set it to zero.

`prepare_mc_local_commit.py` factors the original ordinary-successor commit
expression, byte-for-byte, into `mc_pipeline_commit`. The public
`mem_next_commit` remains AGI OR reference OR that expression. Only the two
pipeline accept predicates use the local term instead of the public OR. All
branch-outcome, read-ACK, FP admission, translation, fault, debug and readiness
guards remain. Simulation witnesses retain both original accept equations.
No new state, cycles, port, mode, clock exception or guest-specific behavior.

Three complete input files are hash-pinned and source-audited: the chain,
AGI and reference-prime headers. Exact reversal restores the chain header.
Derivative SHA-256:
`b1e94ba311c54860a56d872aadaff75771c6eff795bb112f2bc0476b3ec29788`.

## Closed local evidence

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.
`mc-local-leaf-r2` passed **262,144 exhaustive Boolean combinations** in
**2.255 seconds**, with **20,480 chain accepts / 10,880 prime accepts / 57,344
other-hint commits / 1,920 rejected branch outcomes**. Original/new commit and
accept expressions are extracted from actual source; selector exclusion is
an abstract contract backed by the separate source audit. Removing either
selector's `!mc_valid_q` in that contract gives a native mismatch. These are
contract-negative controls, not full-core injected RTL mutants.

Service `ventium-mc-local-leaf-r2-oct13`, invocation
`a6d6c801ff4244f1a24a8002ed4bd37d`, closed with exit 0 and stable pins.
Closure SHA-256:
`5de213420c34e05c7970721239e71a4b30f0b78d36fea358757528bcf9f51491`.
The earlier `ventium-mc-local-leaf-oct13` invocation
`85f6eba8a67c4b1fbb5f61922ea8868a` failed **before creating output or running
RTL**: its guard-count assertion omitted the no-fastload branch's explicit
zero assignment. The source audit now checks all three assignments. That
failure remains in the journal and is not a passing test.

## Closed full-core comparison (Oct 13)

`build_mc_local_core.py` preserved the complete **195-file** parent source
closure and all **152 UV-fast defines**, changing only `core_mem_chain.svh`.
The 32-job guarded build completed in **20.268 seconds**, with assertions,
the private C++ harness and its matching generated-header dependency checked.
Model SHA-256: `2c54f961e87147003dd75909a361f1f9213f6453bbe6f1bce8ed512cb3fa94e4`.
Service `ventium-mc-local-core-oct13`, invocation
`53723416bc344cd69d4a5162cfad7890`, is terminal with exit 0.

`run_mc_local_core.py` retained the parent's complete eight-corpus plan and
coverage requirements. `mc-local-corpora-r1` passed in **298.539 seconds**:
load/store, held requests, branches, integer, FP, AGI, reference priming and
AGI/store interactions. All **4,240 probes / 21,190,336 clocks** matched the
parent's architectural and cycle results. Coverage: **18,172 AGI / 24,352
reference / 282,808 prime events; 5,616 paired-store intents / 3,072 requests /
1,872 accepts / 1,536 shape-only cases**. Retained-lookahead events remain zero
in this RAW profile; this is not a test of the disabled retained-owner mode.
The unchanged directed QEMU comparisons remained enabled in their corpora.

Service `ventium-mc-local-corpora-oct13`, invocation
`d3189700ec0143f8b136efc38ab7d1c2`, is terminal with exit 0 and stable input pins.
Build closure SHA-256:
`79f2b2d03ce55e3466073c1e3fb01f674671cadf8e4856bbf7cb5388f28eeb88`.
Corpus closure SHA-256:
`368c50a83e6b31bf1bbcc09348ba452e5e42d1d7094d8ce11309692b23dbc504`.
Two host tests additionally check preservation of build guards and the entire
corpus plan/coverage assertions. These passes do **not** repair or waive the
parent's canonical **7 PASS / 101 FAIL** result; the new model's canonical
gate and full FP/fault/replay qualification have not yet run.

Closed trace/stdout/stderr files were losslessly compacted after native jobs
exited: **38,352 files, 969,145,428 bytes → 87,622,365 bytes**, reclaiming
881,523,063 logical bytes. Every archived member was byte-hash verified before
removing its loose copy; sources, models and receipts remain. Restore with
`tar -xzf closed-mc-local-corpora.tar.gz -C <evidence-root>` when inspecting
the full traces. Archive SHA-256:
`a67ce78ae9e8fcf096970b3e7613c7b0a80645c48d5530848952bf3867de53f5`.
The archive plan, verification and closure receipts are in the evidence root.

## Important remaining work

This cut alone **cannot establish 40 MHz**. The same public hint-commit path
also reaches L1D replacement state at −5.581 ns; that port still correctly
includes AGI/reference commits. Investigate whether own paired-store snoop
terms are redundant under those offers, using their real source and complete
owner/fault/REP invariants. The existing RAW `PAIR-INTENT` assertion checks
`!(mem_store_pair_intent && mem_next_req)`, but an assertion passing directed
tests is not by itself sufficient authority to delete all coherence guards.
Keep external snoops and prior-cycle poison authoritative.

The separate [prime coherence proposal](PRIME_COHERENCE_CUT.md) now addresses
that public hint feedback using the integrated no-memory ownership contract.
It is leaf-qualified only; it has not been combined into a full-core model.

Next: canonical/full FP/fault/replay checks, broader simultaneous-event tests,
then source-matched full-PC regression and synthesis. Do not merge a private
proposal or claim acceptance from this leaf result. Canonical failures,
standard suite and physical FPGA Win95/Quake acceptance remain unresolved.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**; predates the proposal, not FPGA/timedemo IPC.
