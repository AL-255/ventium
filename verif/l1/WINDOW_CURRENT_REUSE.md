# Current-tag saved-window timing proposal

Private derivative, now composed onto the data-size and x87 environment-write
repairs; **not production RTL or accepted hardware**. Target remains at least
40 MHz synthesized Fmax with UV + fast enabled. No timing or gameplay result
exists for this proposal. Root RTL and the installed FPGA remain unchanged.

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

## Sequential cache and composed core

The later data-size checkpoint closed at **35.830735605 MHz unplaced**,
slightly worse than its 35.856430851 MHz parent. Its worst 97-level path still
crosses next-request arbitration and saved-window reuse before paired GPR
writeback. This motivates the current cut; it does not establish a timing gain.

New evidence root:
`/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

`window-current-cache-r1` runs `run_window_current_cache.py` against the
unchanged full-P5 sequential fixture, comparing both reuse predicates,
contextual FP outputs and cache data/tags/LRU/owners on both edges.
It closes in **23.35 s**, with **747,037 comparisons / 463 next-port samples**.
The retained coverage includes 51 cases, 41 pairs, 123 held responses,
66,339 high-window valid samples and 152 blocked samples. A separately
compiled lost-next-owner mutation fails natively at cycle-time 1,021,000.
There are no hierarchical writes to force cache state. Parent and current
core L1/bank-arbiter/hit-return sources were byte-matched before reuse of
this fixture. All 152 definitions and full P5 geometry remain unchanged.

Owner `ventium-window-current-cache-oct13-r1.service`, invocation
`80f1561ee5cd45bc82c5651afbb5e8bf`, is terminal, MainPID 0 / exit 0.
The inner guarded scope used 2,446,008,320 bytes peak RAM and no swap;
its lifetime is within that owner's invocation. Independent read-only checks
rehash all 4,062 input pins and row artifacts. Closure SHA-256:
`fb1f0bba0ca3eb0ab4e9d336f98985c85af2eea72a680b611862e3c055f4cfcb`.

`build_window_current_core.py` composes exactly this L1 file onto the
[environment-write repair](../sys/fp_env_store/WRITE_CLASS.md). All other
194 source files match that parent. The 32-job guarded native build closes
in **26.08 s**, with a unique local host object and its own generated header.
All 152 definitions, assertion checks and board single-fill policy are
retained. Model SHA-256:
`737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7`.
Owner `ventium-window-current-core-oct13-r1.service`, invocation
`366b09ba2b8e4f27b1a2081e8532d0e0`, is terminal, MainPID 0 / exit 0.
Independent source/header audit rechecks 16,826 pins and the exact one-file
transformation. Build closure SHA-256:
`11ce8c9060f541ad8ece307608d70c544ba5d7e8ae606b69f620edacfb2bc8a9`.

The unchanged private-QEMU functional corpus closes **108/108 PASS** in
116.92 s; 105 also pass without the existing manifest masks. The same three
x87 stack tests (`tx_regform`, `tx_regform2`, `tx_stack`) still need their
existing masks. The canonical gate still closes **7 PASS / 101 FAIL**,
native Make exit 2, in 395.52 s.
All 20 canonical cycle traces match the immediate parent exactly. No mask,
golden, cycle band or backend was changed. These are separate verdicts:
the private oracle result does not turn the canonical failure into a pass.

The first independent auditor incorrectly demanded identical records from
two separately launched private-QEMU corpora. It failed on initial ESP:
QEMU's loader stack differs with the launch environment, and stack-dependent
flags/registers consequently differ too. This was **not waived or normalized**.
`run_window_current_same_input.py` instead replays both models on the same
retained flat images and initial ESP, requiring complete unmasked equality
and reproduction of the candidate's original trace. Separate runs and their
original results remain intact.

That same-input replay now closes **108/108**, 216 native model executions,
**80,800 complete records**, in **172.06 s**. Every per-test clock count and
paired-retirement count is identical: **30,132 V retirements** on each model.
These are directed tests including exit quiescence, not gameplay or a
performance-gain measurement. Actual child affinities and waits are checked;
the 2 GiB/no-swap owner reports no OOM.
Owner `ventium-window-current-same-input-oct13-r1.service`, invocation
`547dad23ce1d4594a8645b8e80aea5a5`, is terminal, MainPID 0 / exit 0.

`audit_window_current_checks.py` independently rechecks 18,147 pins,
complete private comparisons, the same-input records, clock/pair counts,
all 20 cycle traces and terminal owners. It preserves the canonical failure.

| Closed evidence | SHA-256 |
| --- | --- |
| `window-current-same-input-r1/closed.json` | `7ae3427fcb1432d9ada0efdfe49397521ebe69c209d1858d9e401d19f736ccfc` |
| `window-current-core-r1/verify-closed.json` | `b4f2fee8470af22dada5a64f1813dff9b17a44f89245a57f9d435fb147503070` |
| `window-current-regression-audit.json` | `1dd4b7175a442465dac426b026255b283acfd9d985bda1d9e7893b5872cddf28` |

## Still required

Full-PC regression, FPGA source transfer and measured timing remain open.
Existing canonical failures remain unwaived. Full standard-suite and physical
FPGA Win95/Quake acceptance remain required; no reduced-mode pass substitutes.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this proposal and is not FPGA or
full-timedemo IPC.
