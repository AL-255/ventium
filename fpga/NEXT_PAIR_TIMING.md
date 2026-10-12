# RAW next-read / paired-store timing experiment

Target: **at least 40 MHz synthesized Fmax**, UV+fast, full P5 caches.
This is an **unqualified timing candidate**, not a frequency or FPGA pass.
The last measured parent remains **30.591330 MHz** unplaced, setup **−7.689 ns**
at 40 MHz. See [the parent timing audit](BACKING_PAIR_PAYLOAD.md).

## Reason for the change

The parent's 111-level worst path passes through V-branch lookahead,
next-read translation/permission checks, L1 read/store-pair readiness, backing
ACK and interrupt-return control. The L1 check excluding a concurrent next-read
is important: next-read lookup redirects a shared cache port. Removing that
check outright could lose a V store or corrupt cache coherence.

Instead, `prepare_next_pair_cofactor.py` exposes an earlier, redundant core
exclusion, **only with the existing RAW-hint and load/store-pair defines**:

```systemverilog
assign mem_next_req = (agi_prime_offer || ref_prime_offer || mc_offer || mc_prime_offer) &&
                     !(pipe_load_req && pipe_store_pair_shape);
```

Other configurations keep the original equation. The candidate retains an
assertion comparing the new request with the complete original equation on
every post-reset clock. No cache arbitration, permission, address, data,
retirement, golden, tolerance, clock or timing-exception change is intended.
Whether synthesis actually removes the late dependency remains to be measured.

### Why the exclusion is plausible, and its limit

- AGI hints select a paid AGI clock with no active memory owner; actual fresh
  load requests exclude that clock.
- Reference hints use the reference-only dispatch path, not a checked paired
  integer load/store packet.
- In the RAW profile, `mc_prepare_ok` requires `mc_prime_base`, while retaining
  `mc_valid_q` requires `mc_prepare_ok && !mc_prime_base`. Reset initializes
  that owner to zero. The probe also checks that it stays zero.
- Fresh/held raw hints use the current/saved V descriptor. A V store is not a
  read-hint descriptor. Register/FP/branch priming has different current-U
  eligibility from an actual U-read/V-store packet.

These source arguments plus directed simulations are **not a formal proof over
all processor states**. Fault/event coverage, broader regressions, the standard
suite, synthesis/routing and physical FPGA acceptance are still required.

**Do not gate on `pipe_store_pair_shape` alone.** A new cold-boot microbenchmark
puts an address-writing LEA immediately before U load + independent V store.
The AGI edge has a valid pair *shape*, but no actual load request; its useful
resident hint must survive. The negative control rejected this overly broad
exclusion on real decoded instructions, without forcing internal state.

## Closed evidence, October 12

Evidence directory:
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

| Evidence | Result |
|---|---|
| Unmodified-core probe model | `7ce9cfa450ee674e59fc296503153ac9c9fd24b03f52f9175e04bce5eb482f32`; native build 20.819 s, source pins unchanged |
| Independent probe audit | `next-pair-probe-audit-r1.json`: 4,240 candidate simulator invocations; 21,190,336 observed clocks; no overlap/retained-owner assertion fired |
| Observed predicate counts | 18,172 AGI offers; 24,352 reference offers; 282,808 raw-prime offers; 5,616 actual-read/pair-shape clocks; 1,872 accepted read/store pairs |
| Broad-exclusion counterexample | 1,536 shape-only overlap clocks; `shape-only-negative.log` exits 1 with `NEXT-PAIR-BROAD`, showing `load=0 agi=1` |
| New candidate model | `5b8c134e4e3d4c6856025ce37d0abdf1cd3bfc424baaae837fa393130d3a541a`; native build 19.670 s, source pins unchanged |
| Hardware-profile preprocessing | `next-pair-synth-delta-r1`: exactly one combinational request-expression change; no added hardware state/ports; diagnostic counters/assertions absent under `SYNTHESIS` |
| Candidate load/store corpus | Complete QEMU state and exact parent/candidate clocks pass; 228 same-line and 228 other-line V-store retirements across the measured cases |

Probe totals include the separate `--cycle` and `--cycle-func` executions.
They are neither unique workload cycles nor gameplay performance measurements.
All models keep the same 152 simulation defines, assertions, UV+fast and AXI
backend. Both builds use a fresh, model-specific C++ harness basename, verify
its local object and matching generated headers, and use the shared guarded
32-job build profile. The synthesized RTL delta is checked separately from
the simulation-only instrumentation.

### Retained failures and reruns

1. `next-pair-probe-tests-r1` completed all five native corpora successfully,
   then its summary collector incorrectly selected a comparator's
   `cycle-func-diff.stdout` as simulator output. The failed receipt is retained.
   `audit_next_pair_probe.py` checks every underlying successful suite and
   collects only commands that actually invoke the AXI model. It combines
   these with the separately passed AGI/reference/AGI-store supplement.
2. `next-pair-cofactor-checks-r1` passed load/store tests; held-read case
   `(4,0,31)` lost QEMU's initial debugger handshake with
   `ConnectionResetError`, before either model ran for that case. The other
   46 held-read measurements completed. This failed attempt is retained.
   `run_next_pair_held.py` assigns separate ports 27000–27023 outside the host's
   ephemeral range and preflights availability. Images, comparisons and
   performance requirements are unchanged in the queued R2 run.

Canonical `make verify` closed after **401.164 s**: native exit 2, **7 functional
PASS / 101 FAIL**. All **20** cycle traces match the parent exactly; source pins
are unchanged and no masks, goldens or tolerance bands changed. This gate is
**red and unwaived**. Directed passes do not replace it.

The complete cofactor R2 checks closed successfully after **301.082 s**:
all eight native corpora passed, including all 48 held-read measurements.
The **4,240** simulator invocations have exactly the same aggregate predicate
counts and **21,190,336** observed clocks as the unmodified probe. Every full
QEMU architectural comparison and parent/candidate retirement-clock comparison
in those corpora passed; the request-equivalence assertion stayed enabled.
There is no closed candidate synthesis, route, duration-valid CoreMark score,
full timedemo or FPGA acceptance. In particular, no frequency gain is claimed
from these tests.

Two closed probe compiler PCH files were gzip-compressed and checked with
`gzip -t`. Their `.gch.gz` files preserve the full contents; source, executable,
objects and verification evidence were not deleted.

After all owners closed, `closed-next-pair-vectors.tar.gz` losslessly archived
19,083 files: the closed probe/supplement/R2 `.vtrace` outputs and the two
candidate compiler PCH files. Every archived member was size/SHA-256 checked
before removing its uncompressed copy. This changed 1,699,996,357 bytes into
110,929,811 bytes, recovering **1.48 GiB**. The archive's plan, verified receipt
and closed receipt retain the exact file list, hashes and terminal owner IDs.
Current input pins, source, models, images, logs, JSON receipts and canonical
gate traces remain in place. Restore archive members before reusing raw traces.

## Whole-PC transfer and bounded synthesis

The exact candidate transferred into the frozen PC platform without changing
its other RTL, DMA repair, 156 defines or 16-entry posted-write configuration.
All 102 shared core source files were checked; only `core_mem_chain.svh`
changed. Native compilation closed successfully in **23.705 seconds**, with a
fresh private harness object and matching generated-header dependency. The
model is `6e26dd39ea94482a0d1eb65d84c26d8dadfa6d73b24f853aea03a2fec629ec80`.
The **98 inherited structural diagnostics remain**; this is not a clean full-SoC
lint result.

`next-pair-cofactor-fpga-r1` preserves 190 payloads, 170 common HDL inputs,
158 hardware defines and the original 40/100 MHz clocks. Its manifest is
`a13b84ce9ea8fa810914e3526d170129869ab7b1d2a335d3fcfefc9c9488860c`.
Strict CPU-hierarchy lint passed in **3.928 seconds** against this export.
No cache geometry, external port or timing exception changed.

The independent short CoreMark audit closed both cold-boot seeds with all five
CRCs matching QEMU, exactly **4,767,218 / 4,753,406 ticks**, and actual V
retirement counts **1,055,307 / 1,054,254**. All 11,455 source pins were rechecked;
both native children exited and no OOM occurred. The cycle counts are identical
to the parent: **zero measured throughput gain**. These ten-iteration tests
retain the expected under-ten-second duration error and are not publishable
scores or error-free standard-suite passes.

`next-pair-cofactor-replay-r1` closed all **108 programs / 80,800 records** with
complete same-input parent/candidate equality. A direct comparison of separately
generated historical traces was rejected because their QEMU-provided initial
stack pointers differed. The replay actually runs both models with identical
images and initial state; it does not mask ESP or any other fields. The original
canonical gate remains **red and unwaived**.

The first synthesis controller, invocation
`6be311b8f76e40b38786ad773e10b123`, stopped during disk admission, **before any
Vivado process launched**. Free space exceeded 6 GiB but did not exceed twice
the measured parent's 1,456,762,880-byte growth above the 4 GiB stop floor.
The refusal and journal are retained in `admission-failure.json`.

After lossless archival restored the unchanged reserve, the controller restarted
at **18:55:10 UTC** as `ventium-next-pair-cofactor-synth-oct12.service`, invocation
`2fff17acfee741be81f281d2264a24d2`. Its single Vivado scope invocation is
`deed97be6a9749c8984f6fde39113669`. The matched `Default -no_timing_driven`
synthesis is a structural diagnostic, not timing closure. Bounds remain one
worker, 8 GiB resident / 6 GiB swap, 13 GiB combined early stop, 2 GiB host
reserve, 4 GiB live disk floor and 45-minute native timeout.

`ventium-next-pair-cofactor-report-queue-oct12.service`, invocation
`4017a795c0f8441fa0378de46989ce76`, observes only that exact synthesis owner.
After native closure and an independent source/DCP/DMA audit, it may launch
one guarded, read-only original-clock timing comparison against the retained
best **MEMDIV-QUERY 30.676729 MHz** checkpoint. It cannot retry synthesis,
start placement/routing or deploy. At this update synthesis is running, so
there is **no candidate Fmax result or 40 MHz claim**.

Space recovery is reversible. `closed-next-pair-synthesis-reserve.tar.gz`
contains 10,731 closed old traces/large reports: 2,061,281,628 source bytes became
88,762,335 archive bytes. `closed-next-pair-pch.tar.gz` contains another 857
closed compiler-cache/failed-run trace files: 235,226,722 bytes became
34,298,253 bytes, recovering **192 MiB**. Every member's size and SHA-256 was
verified before removing its unpacked copy; sources, models, images, active
inputs, native logs and receipts remain. Exact member lists and recovery hashes
are in the adjacent `*-plan.json`, `*-verified.json` and `*-closed.json` receipts.

## Reproduction entry points

All commands use `TMPDIR=/home/yukidama/external/tmp` and fresh output paths.
Build/test fan-out goes through `tools/build_scope.sh`, profile
`ipc_parallel32`, explicit Verilator 5.046. Never overlap a Vivado family.

- `verif/l1/build_next_pair_probe.py`: prepare/build the unmodified-core probe.
- `verif/l1/run_next_pair_probe.py`: historical first collector; use its
  retained failed receipt plus the independent audit, not its overall status
  as a native correctness result.
- `verif/l1/run_next_pair_supplement.py`: AGI/reference/AGI-store tests and
  shape-only negative control.
- `verif/l1/audit_next_pair_probe.py`: closed-probe source/log/coverage audit.
- `verif/l1/build_next_pair_cofactor_core.py`: prepare/build only after that
  audit passes, preserving the original parent identity and source closure.
- `verif/l1/check_next_pair_synth_delta.py`: preprocess both exact profiles and
  require the sole hardware-expression delta; this is **not Vivado synthesis**.
- `verif/l1/run_next_pair_cofactor_checks_r2.py`: all eight same-profile
  corpora, exact A/B clocks/state, real V stores and all hint-producer coverage.
- `verif/issue_uv/run_fp_nomem_verify.py`: unchanged canonical gate; failures
  and all 20 parent/candidate cycle-trace comparisons stay visible.
- `fpga/build_next_pair_cofactor_soc.py`: exact PC transfer and guarded build.
- `fpga/freeze_next_pair_cofactor_rk_candidate.py`: source-matched FPGA export.
- `fpga/prepare_next_pair_cofactor_synthesis.py`: hash-pinned controller
  derivation; five tests in `test_prepare_next_pair_cofactor_synthesis.py`
  check source identity, replay admission and unchanged resource/clock bounds.
- `fpga/audit_v_carry_payload_coremark.py`: unchanged short-seed closure audit.
- Evidence-root `report_next_pair_timing_after_synth.py`: exact-owner synthesis
  closure, native timing audit and explicit measured-40-MHz result; no routing.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement-event IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not a physical
FPGA or full-timedemo average.
