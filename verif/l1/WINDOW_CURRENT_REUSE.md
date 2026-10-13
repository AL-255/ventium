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

## Page-fault replay and hardware-source transfer

`run_window_current_env_faults.py` repeats the unchanged environment-store
corpus on the composed core: **44 cold fixtures, 88 complete functional
comparisons**, with AXI latencies 0 and 7. All fixture images match the prior
repair's images. The successful `window-current-env-fault-r2` closes in
**12.43 s**, with real paired execution and backing-memory acknowledgments.
Owner `ventium-window-current-env-fault-oct13-r2.service`, invocation
`17ecb2c1eebc4b1e8c11fb18edc4ba79`, is terminal, MainPID 0 / exit 0.
The failed R1 is retained: 43 rows passed; one golden producer could not
connect to its QEMU GDB stub within 20 seconds. Both RTL executions of that
case passed their self-checks, but without a golden it was correctly a FAIL.
No comparison, timeout, fixture or observation requirement changed for R2.

An independent read-only pass rechecks **16,836 inputs, 1,937 artifacts and
35,124 records** across all 88 comparisons. All emitted RTL fields equal
the corresponding QEMU fields. Raw dictionaries are not identical across
producers: QEMU additionally emits instruction `bytes`, `fs_base` and
`gs_base`; this RTL producer omits those optional fields. Both QEMU bases
are zero throughout these fixtures. This is an explicit trace-coverage
limitation, not a claim to have checked unexposed segment bases. The unchanged
`compare.py --mode func --all` passes; no trace was filtered or rewritten.

`build_window_current_soc.py` transfers **exactly two files** from the
data-size full-PC parent: the environment-write decoder repair and this L1
cofactor. All **102 shared RTL files** match the tested core. The 156 full-PC
definitions, posted-16 transport, `cycle_mode=1` and single-fill policy remain
unchanged. The 32-job guarded native build closes in **24.55 s**, with its own
host object/generated header, no OOM and the same **98 platform structural
warnings**. Those warnings remain separate debt, not a full-SoC lint pass.
Model SHA-256:
`da16060952d983b02d4373038e3faccc5cc8d577e7635c3ae1d104314c08098e`.
Owner `ventium-window-current-soc-oct13-r1.service`, invocation
`5cb78f0b6dfc4699854adc22394b3e42`, is terminal, MainPID 0 / exit 0.

`freeze_window_current_rk_candidate.py` exports 190 payloads, matching all
170 compiled HDL inputs, with unchanged 158 hardware definitions and
40/100 MHz constraints. Three exact-delta/drift/reapplication tests pass.
Manifest SHA-256:
`09160fa65d1b67dcfd9bc263715c5b73475c04410991a3941e651f3eb59fa7c8`.
Independent rechecking covers all payloads and **20,370 freeze input pins**.
Strict hardware-profile CPU-hierarchy lint passes all six structural error
classes in **3.88 s**; this is not full-platform lint.

Both original short CoreMark seeds cold-boot and finish with unchanged
reference CRCs. Performance: **4,767,218 cycles**, V=1,055,307; validation:
**4,753,406 cycles**, V=1,054,254. Native runtimes are 213.90 s / 213.59 s.
**0% cycle-throughput gain** is observed, as expected for this timing-only
rewrite. Ten iterations are **not duration-valid scores**, gameplay IPC or
standard-suite acceptance. `audit_window_current_coremark.py` rechecks
20,215 source pins, both native CPU12 affinities, child closure, media hashes
and exact immediate-parent counts. Owner
`ventium-data-size-cm10-window-current-oct13-r1.service`, invocation
`04206b3e0d19438e92054b463f4864bd`, is terminal, MainPID 0 / exit 0, no OOM.

| Closed evidence | SHA-256 |
| --- | --- |
| `window-current-env-fault-r2/closed.json` | `39b6e6fe0bde0c9a4d4c13cddbacf9705ba54ea36c7e58423c7aec782b18c848` |
| `window-current-soc-r1/build-closed.json` | `9be24bcb0e1f8735b0f7649f878e2a44631bf4d5f2d6a3120a025d31317d48f0` |
| `window-current-lint-r1/closed.json` | `55d9d3b2824553be0ec49550013dd16b0e6c4e8afb0af8be720b6998c3166674` |
| `window-current-soc-r1/coremark/audit.json` | `39070d50b69413d826aed5ab3509ec22adc2752276c72035901ab00870c99430` |

## Timing experiment and resource handling

`prepare_window_current_synthesis.py` preserves the previous controllers'
native lifecycle, guards and reporting Tcl byte-for-byte. Its three tests
check exact source deltas, unchanged 40 MHz constraints and rejection of
weakened memory/cleanup guards. Synthesis still requires over 6 GiB free disk
and twice measured prior growth above a 4 GiB stop floor, plus the existing
host RAM/swap reserves. Only the exclusive single-Vivado launcher is used.

Twelve **unpinned precompiled-header caches from closed builds** were
losslessly archived, read back and SHA-256 verified before removal. This
frees **0.84 GiB net**; no source, model, media, dependency or log was removed.
The recoverable archive is `closed-data-window-pch.tar.gz` under the evidence
root, hash `bf665451c6a8f979311fcafb487e95bd447411da3957d09b98834ee27ff76da8`.
Its plan lists each original relative path/hash; restore from the external
scratch root. All input pins were rechecked after pruning.

The first synthesis-controller invocation
`a494873c47334e5ab5f0dfb96fb92376` failed admission **before native Vivado
launch**: 6.618 GiB was above the simple 6 GiB minimum but below the
6.713 GiB growth-derived reserve. `admission-failure-r1.json` preserves that
failed attempt; there was no `started.json` or native run to grade.

After CoreMark's terminal closure, the final two full-PC PCH caches were
also archived and byte-verified, freeing another **0.15 GiB net**. Archive
`closed-window-soc-pch.tar.gz` has hash
`524d6118f92ce7d6f8819b7a8c1663d610031c5eb4b3bdf785ba5d1e05625cf1`.
All source/artifact pins still match. **No guard was relaxed.**

The unchanged controller was then relaunched under
`ventium-window-current-synth-oct13.service`, invocation
`f124e2fdd07344ce99447cbef6fdbee3`; actual native launch is **22:10:13 UTC**.
The single Vivado family is owned by scope invocation
`91a5533979b845b9919014b7b42f193c`, with the verified 8 GiB RAM / 6 GiB swap
caps and 4 GiB live disk floor. That native attempt **timed out at 22:55:16 UTC**,
exit **124**, after **2,703.29 s**. It was still in cross-boundary/area
optimization. The controller is terminal with MainPID 0 / exit 1; no DCP or
frequency result was produced. All input pins are unchanged, and there was
no OOM, resource-stop event or controller exception.

The launch had accidentally confined the controller and all inherited native
workers to **CPU17 alone**. Actual thread-affinity checks found two synthesis
workers competing on that CPU. The two successful parent synthesis units had
no such single-CPU pin. This is a launch error that serialized worker execution,
not evidence that the RTL alone caused the longer wall time. At 22:53:05 UTC,
the same owned family was widened to CPUs16–19, with PID/start-time checks;
`affinity-correction.json` records all 18 processes / 28 threads. This was too
late to finish before the unchanged 45-minute deadline. No timeout, memory,
feature, timing constraint or RTL change was made to rescue R1.

After terminal closure, only the failed generated project and two unused PCH
caches from a closed full-PC build were recoverably archived. The **885 files**
were read back and SHA-256 verified before unlinking, freeing **579,813,235
bytes net (0.54 GiB)**. Top-level native logs, watchers, controllers and failure
receipts remain; generated child logs are in the archive. Successful DCPs,
source freezes, live guest binaries and media were not removed. The archive
is `failed-window-project-and-unused-pch.tar.gz`, SHA-256
`cbeb0a8726817e3234d8789f446e1d4d10c539d0df856da5067341e72c78a51e`.
`failed-window-archive-{plan,verified,closed}.json` retain the exact paths and
checks. Restore members relative to the canonical external scratch root.

[`prepare_window_current_retry.py`](../../fpga/prepare_window_current_retry.py)
creates fresh R2 owners/directories from the five hash-checked R1 controllers
and timing Tcl. Reversing only path/unit-name substitutions recovers the
original bytes. The frozen source manifest, full-PC model, 158 definitions,
40/100 MHz constraints, admission reserves, resource limits and deadlines are
unchanged. R1's failure is retained, not overwritten.

R2 launched at **23:01:58 UTC** under
`ventium-window-current-synth-oct13-r2.service`, invocation
`182429bc7bb441db8454bda28a98c02d`; its single native family has scope invocation
`f3c48b23ecc0409a8fbfc649f8c3c30e`. At 23:05:30 UTC, all 19 live native-family
threads were read back with actual affinity **CPUs16–19**. The verified caps
remain 8 GiB RAM / 6 GiB swap / 48 tasks. **R2 is running; no new frequency
result yet.** The separate [V-load payload leaf](../issue_uv/V_LOAD_PAYLOAD.md)
is not in these synthesis inputs. These controllers cannot start
implementation, routing or board programming.

## Still required

Measured timing and full-PC standard-suite qualification remain open.
Existing canonical failures remain unwaived. Physical FPGA Win95/Quake
acceptance remains required; no reduced-mode pass substitutes. The existing
FPGA's [Doom startup failure](../../docs/FPGA_DOOM_2026-10-13.md) is unchanged,
and neither physical nor simulated Doom FPS is available.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this proposal and is not FPGA or
full-timedemo IPC.
