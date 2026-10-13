# Current-tag saved-window timing proposal

Private derivative of FP-WIDE-CONTEXT, **not production RTL, the currently
running FPGA synthesis, or accepted hardware**. Target remains at least
40 MHz synthesized Fmax with UV + fast enabled. No timing or gameplay result
exists for this proposal.

## Reason and exact change

The measured PAYLOAD-REGION captured-V path has 99 logic levels and setup
slack −3.804 ns: EIP/decode → paired branch lookahead → address/DTLB checks →
next-request arbitration → saved-window reuse → pair admission → captured V.
This is an independent failing endpoint, not the FP endpoint addressed by
FP-WIDE-CONTEXT. Source: `payload-region-clock-r1/candidate_capture_paths.rpt`
under the evidence root below.

Both `window_reuse` and `shadow_reuse` already require a current idle read,
`c_req && !c_we`, with early/stream paths excluded. `mc_lookup_prime` requires
`!c_req`, so cannot apply there. Under the unchanged guards, `mc_lookup_old`
reduces to `c_next_req && rd_match && !c_pair_intent` (or without the last term
when paired stores are disabled). When arbitration permits reuse, the selected
hit must be the **current** tag hit.

`prepare_window_current_reuse.py` applies those identities to just the two
reuse expressions, using current tags directly and retaining residual
old-owner arbitration. It preserves line validity, residency, extent, code,
cacheability, flush and snoop checks. There are no added ports, registers,
cycles, feature flags or clock exceptions. Simulation witnesses compare both
new expressions against their original equations. No core-only assumption
that next requests cannot occur is made.

The recipe accepts only L1 parent SHA-256
`d565f12a984a4e83c8816a0214705999033a2c0906ad66f44f27d5b117b4d4f8`.
The derivative is
`a0d3ed6f8fc725975a6833facd4c87adb5ee8f8114d6dd0ea9fbb6b3982d44bf`.
Drift and reapplication are rejected; reversing the documented changes yields
the exact parent bytes.

## Closed evidence

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

- `window-current-leaf-r3`: **344,071 comparisons per profile**, nine profiles,
  **3,096,639 total**, 14.150 seconds, 21,659,648-byte peak memory. Actual old
  and new assignments are preprocessed/extracted into an Icarus miter.
  Profiles cover full features, no paired stores, no code buffer, primary
  window only, no chain (with/without code buffer), no windows, no prime and
  no prime-under-fill. Six compiled mutants fail for lost next ownership,
  wrong tags, missing flush/snoop, wrong extent and missing code exclusion.
  Service `ventium-window-current-leaf-r3-oct13`, invocation
  `a6695e4eeb1b47e5886cf8d105b356da`, closed with native exit 0. Closure hash:
  `9fd9ae2c164cef820406026e6df51f95cbd600151704138a2b33ea34856fda11`.
- `window-current-proof-r1`: four UNSAT queries establish primary/shadow
  equivalence, current-read exclusion of prime and current-tag selection.
  Four SAT queries demonstrate lost-next-owner, wrong-tag, lost-residency and
  lost-primary-owner counterexamples. Source/artifact pins are rechecked.
  Service `ventium-window-current-proof-oct13`, invocation
  `2440a9fc54fb4f4cbe9175b2d0ecb488`, closed with native exit 0. Closure hash:
  `4723015457e837e829adea3f5f9450a8088cfea4a8eefcf3afe7fa67aa4def12`.

The SMT queries are a **manually stated abstract Boolean/bitvector contract**,
not automatic formal elaboration of the SystemVerilog. Independent hit/match
inputs over-approximate the leaf. Native comparisons cover binary values,
not X/Z behavior. Neither proves sequential cache behavior or the whole core.

Two failed harness attempts remain recorded, not counted as passes:
`window-current-leaf-r1` expected one mutation anchor where both preprocessor
branches exist; `r2` incorrectly required prime coverage in the newly added
no-prime configuration. Commits `c5b25d91` and `673485b2` preserve these
stages. The corrected coverage requires prime activity only when enabled and
requires zero activity when disabled. No RTL failure was hidden by either fix.

## Still required

Inspect FP-WIDE-CONTEXT's completed timing report before choosing this next
candidate. This proposal still needs full-cache sequential A/B, native core
and full-PC regression, FPGA source transfer and measured timing. Existing
canonical failures remain unwaived. Full standard-suite and physical FPGA
Win95/Quake acceptance remain required; no reduced-mode pass substitutes.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this proposal and is not FPGA or
full-timedemo IPC.
