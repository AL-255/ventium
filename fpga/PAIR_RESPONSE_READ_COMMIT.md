# Paired-load response timing investigation — October 11, 2026

**Private RTL recipe and extracted tests; no whole-core build or timing result.** The target remains
at least **40 MHz synthesized Fmax**, preserving UV, fast pipes and full P5
caches. The measured readiness predecessor is **30.34809 MHz**, unplaced.
[The read-hint commit candidate](MC_READ_COMMIT.md) is still synthesizing.

## Another measured path, not the same-line ACK draft

The predecessor's separate `candidate_capture_paths.rpt` reports
`eip_reg[0]/C → pipe_mem_v_hit_q_reg/D`: **109 logic levels**, **32.095 ns**
data delay, **−7.306 ns** setup slack at the original 25 ns period. That path
alone corresponds to an unplaced **30.95400 MHz** estimate. This is neither
the current candidate's Fmax nor a prediction of its eventual result.

The reported suffix runs through `pipe_int_commit`, `core_pair_rsp_ready`,
`pair_leaf_req_ready`, and V-hit capture. The read-hint change does not alter
that response-consumption equation. This is distinct from the deferred
[same-line immediate-return ACK draft](PAIR_NOW_ACK_CUT.md); applying that draft
alone would not explicitly remove the architectural-commit dependency here.
Rebuilt netlist hierarchy names are not a reliable RTL module-ownership map.

Report:
`/home/yukidama/external/tmp/ventium-pair-ready-cofactor.btYwXlBN/clock/candidate_capture_paths.rpt`.
SHA-256: `35bf7a2053105d978d24629a1364897e238388f2e7ab6c8b91eb3b85be7f0d14`.

## Proposed cut and necessary invariant

In the actual target, `VEN_P54_DUAL_LOAD_PAIR` and raw read priming are enabled,
but `VEN_P54_DUAL_LOAD_PRIME` and `VEN_P54_REGMEM_PRIME` are **absent**. Only a
fresh paired U/V load can set `pipe_mem_v_hit_q`. Its existing admission
assertion requires a new U read, no current U owner, no ACK and no abort.
The corresponding U owner is captured on that same edge. Completion, terminal
states and precise faults clear the V owner with U; replacement creates a read
owner. Raw next-read hints do not create a new architectural owner.

This supports the profile-specific invariant:

```text
pipe_mem_v_hit_q implies pipe_mem_active_q && !pipe_mem_we_q
```

Under that invariant, the owned paired response can use the read-only form of
the existing integer commit predicate: replace `!pipe_mem_wait` with
`!pipe_store_req && (!pipe_load_req || mem_read_ack)`. Preserve **every other
commit qualifier**, actual architectural commit, fragment-qualified ACK and
the `!pipe_mem_v_hit_q` orphan-drain arm. Do not change the hit-return leaf's
consume-and-replace protocol or create an ACK for an unowned response.

Do **not** extend this proof automatically to the register-U/V-memory prime
profile: there a V owner need not imply an active U memory owner. Those profiles
need their own proof or retain their original predicate. No feature is disabled
in the actual target to obtain this result.

## Executed checks

Evidence root: `/home/yukidama/external/tmp/ventium-mc-read-commit.PNi1O0xm`.
The pinned core SHA-256 is
`8ef0079de0a0f9eba1f48533f590e0908b96fbaea9ff64030183a5e3e0416ec0`.

- [`prove_pair_response_read_commit.py`](../verif/l1/prove_pair_response_read_commit.py),
  `pair-response-proof-r2`: abstract Boolean reset and inductive ownership
  checks plus response-consumer equivalence are **UNSAT** (no counterexample).
  All six deliberately broken variants are **SAT**: store-owned capture,
  missing completion/fault cleanup, missing read ACK, raw fragment ACK, and lost
  orphan draining. This is a handwritten transition abstraction, **not formal
  verification of the extracted full RTL**. It assumes the existing fresh-V
  admission assertion and leaves the other issue/fault/ACK inputs arbitrary.
- [`test_pair_response_read_commit.py`](../verif/l1/test_pair_response_read_commit.py),
  `pair-response-leaf-r2`: Icarus executes the actual extracted request/commit
  equations and U/V owner-update blocks, with a narrow fixture for external
  inputs and precise-fault clearing. **77,834 checked clocks**, 5,108 owned
  response samples, 4,083 owned read-wait samples and 6,162 acceptance samples
  pass; these are not full-CPU instructions or unique cache transactions.
  A 4,096-case structured sweep starts with a real fixture-owned response before
  varying control conditions, rather than relying on sparse random admissions.
  Missing ACK, raw fragment ACK, lost orphan drain and lost fault clear variants
  all compile and fail natively (exit 1); positive exits 0 in a 1.66-second run.

All R2 input and generated artifact hashes independently recheck. Proof receipt
SHA-256: `969c5f6b0cdfe11857b53c27b0854d3db7ee4575472fe952f9af3239042b7d86`.
Native receipt SHA-256:
`faef147359b7a2fc1bec001525daa7bab6937652ef94907eea338d2b8aa72c72`.

The retained first proof had an unnecessarily restrictive `is_mem` condition on
the abstract store request; R2 removes it to match the actual source. The first
native sweep passed but sampled only four owned-response clocks; R2 adds the
structured ownership sweep. Their generated problems/testbenches and logs
remain, but their repository driver pins are superseded. Use R2, not R1, as the
current evidence.

Neither fixture instantiates the complete core/cache or proves translation,
decoder admission or backpressure integration. Before promotion: wait for the
current measured timing result, then build the isolated derivative and run
full-core memory/store/FP/fault A/B and unchanged canonical verification,
full-PC checks and matched synthesis. Current canonical verification is still
**FAIL**. No 40 MHz result,
full standard-suite pass, routed timing or physical FPGA acceptance is claimed.

## Exact private recipe prepared, not promoted

[`prepare_pair_response_read_commit.py`](../verif/l1/prepare_pair_response_read_commit.py)
now implements that cut in a private derivative of the exact pinned core.
Only the paired-response-consumption equation changes. Architectural
`pipe_int_commit`, the response slot, requests, owner transitions and clock
count remain untouched. The active raw/no-dual-prime branch gets live assertions
for both the ownership invariant and complete old/new response-ready equality.
Other priming profiles retain the original equation; no build define changes.
Source drift and reapplication reject before producing a candidate.

[`run_pair_response_read_commit.py`](../verif/l1/run_pair_response_read_commit.py)
reuses the owner stimulus but substitutes the **actual recipe**, including its
guards and assertions, for the prospective test equation. `pair-response-recipe-r1`
passes the same **77,834 clocks** and rejects all four native mutants in
**1.79 seconds**. Four preprocessing checks verify target selection and exact
preservation of the old equation in nonraw, dual-prime and regmem profiles.
These are guard checks, not full execution coverage of those other profiles.
All native logs, binaries, generated sources and input pins independently rehash.
New private core SHA-256:
`8d0c3c35eca0c3ea97981d3f33178ef0c656a2eb90f27faea97fe998ab5e24a0`.
Recipe receipt SHA-256:
`5062c51508e1ba1815cbaf61f01ab9fca11eb578387d3715b3f75619af814d00`.

[`build_pair_response_read_core.py`](../verif/l1/build_pair_response_read_core.py)
is prepared, **not launched or queued**. It admits only the compiled read-hint
parent `64dadfc9…`, its exact read-hint header, successful actual-recipe/native
tests and the R2 ownership proof. It keeps all 195 sources / 150 definitions,
changing only `core.sv`, and checks the private harness's own generated header.
Native-exit/guard/proof/coverage admission checks accept the real receipts and
reject 21 deliberately bad variants. They are builder checks, not a CPU pass.
The guard requires the shared heavy-build scope and no live Vivado, so this
preparation does not compete with or mutate the running read-hint synthesis.

### Integration after actual clock closure

The read-hint clock audit subsequently closes at **29.58405 MHz**, with the
worst paths entering the SRT divider. Its separate V-response path is still
limited to **30.43955 MHz**. The [combined follow-on](MC_PAIR_SRT_TIMING.md)
therefore integrates this **exact tested core recipe** and the independently
tested SRT normalization tree. Its actual full-core build and 216 memory/store/FP
fixtures pass with identical A/B cycles. The standalone one-file builder above
still has not run; the combined model is not a standalone attribution of either
change's timing gain. New synthesis, standard-suite and board acceptance remain
open.

Verified gameplay baseline: **0.51030715 total U+V simulated retirement-event
IPC**, older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. The current
timing candidate and this private derivative have no gameplay measurement.
