# Branch-fallthrough ownership sharing — October 11, 2026

**Directed regressions pass; canonical verification remains FAIL. No timing or
FPGA acceptance yet.** This targets the
remaining late I-cache ownership lookups seen in the retained MC-address
V-capture path. The combined synthesis was not modified by this experiment; it
subsequently hit its 30-minute limit before checkpoint completion, with no Fmax.

## Change

`mc_descriptor` checks a small MOV after a paired branch. Although its outer
guard proves `pc == eip + off` with `off <= 13`, it performs two arbitrary
I-cache ownership lookups at `lin` and `lin + len - 1`. These follow late PC
selection and decode. The frontend already computes the current/next line's
tag, winning way, returned-buffer identity and collision checks.

[The recipe](../verif/l1/prepare_mc_branch_residency.py) replaces only those two
calls with the existing `ic_res_buffered_offset/end` helpers, under the already
enabled `VEN_IC_RESIDENCY_SPAN`. The original calls remain when it is disabled.
All PC/page/segment/line bounds, byte selection, decoder logic, priority,
request/commit predicates and address equations stay unchanged. No extra port,
cache-size change, clock exception, pipeline stage or serialization is added.

The transformation starts from the combined candidate's exact header
`5d2044b0…`; the generated header is
`e044fcd954b5c2a0f0151e5e83198833faeffa875a776f17bb388fb2e21614cc`.
It does not modify the source pinned by the active synthesis.

## Closed isolated checks

Four [recipe tests](../verif/l1/test_mc_branch_residency.py) pass. Z3 proves the
32-bit modular address identities for arbitrary CS bases/EIPs and decoded
lengths, including wraparound; the existing guard bounds the helper count to
28 and its six-bit position sum to 59. Wrong-offset and wrong-line alternatives
have counterexamples. This is an arithmetic proof, not whole-core formal proof.

[The native miter](../verif/l1/run_mc_branch_residency.py) extracts both complete
descriptor functions, the real raw-MOV decoder, real I-cache functions, current
frontend span and existing residency helpers. It reuses the existing fixture's
18 cache/returned-port scenarios, every start offset and U/V length, set/tag
carry, full-address wrap, duplicate tags, bypass priority, swapped/missing/
way-stale/collided buffers, and directed four-state inputs. It does not replace
ownership with a mocked per-byte table.

| Configuration | Full descriptor comparisons | Additional helper checks | Accepted first queries | Native exit |
| --- | ---: | ---: | ---: | ---: |
| Fetch bypass enabled | 1,771,072 | 221,344 | 64,024 | 0 |
| Fetch bypass disabled | 1,771,072 | 221,344 | 63,552 | 0 |

Each configuration includes 885,536 wrong-PC queries that must remain rejected.
Both compiled negative controls fail with descriptor mismatches: substituting
mere tag presence loses returned-buffer ownership; using the current line for
both endpoints loses next-line identity. All input hashes remain unchanged.
The test covers settled four-state behavior, not fixed-address event sensitivity
or sequential processor execution. The existing fixture refreshes the address
after cache-metadata changes to accommodate Icarus's function sensitivity limit.

Evidence: `/home/yukidama/external/tmp/ventium-mc-branch-residency.HG9bs2vj/leaf-r1/`.
Service `ventium-mc-branch-residency-oct11.service`, invocation
`ab76f485492d4ae0b7dfbbc6e7164678`, closes in 42.33 seconds; the journal reports
25.1 MiB peak memory. It launches only small Icarus jobs, not another Vivado or
full-core build. Sources, positive/negative logs and receipts are retained.

## Remaining acceptance

The [combined synthesis](TIMING_COMBO.md) closes incomplete at its time limit;
there is no new worst-path report to inspect. This derivative is motivated by
the previously retained MC-address V-capture path and duplicate caller lookups
still present in the combined source. Its frequency benefit is unmeasured.

The [full-core builder](../verif/l1/build_mc_branch_residency_core.py) now closes
successfully after the prior Vivado family and timing queue are confirmed
terminal. It requires the exact combined-model audit and closed
positive/negative leaf results, verifies that the extracted cache functions
match the model's source, and changes only this header. It preserves all 150
core defines and the guarded 32-job command, while allocating a new model-local
harness and checking its generated-header dependency. Two command-relocation
tests pass. The actual build takes **25.45 seconds**, native exit 0, with stable
inputs and the private-header check passing. Service
`ventium-mc-branch-residency-core-oct11.service`, invocation
`916fb46387e24fd48a1e5610c57ec738`; model SHA-256:
`70900101369189169e472a78f7c4ca8ca34dbb99d6f45c0df5115d505b6a4a3e`.

[The unchanged cold matrices](../verif/l1/run_mc_branch_residency_checks.py) are
launched under `ventium-mc-branch-residency-checks-oct11.service`, invocation
`b1a62b6099a94a518998aa79573fdd01`. The controller differs from the combined
candidate's only in its title, single-header change expectation and unique unit
prefix. It retains all 820 fixtures, 32 initial test workers, full QEMU/A-B
comparisons, focused FP faults, unchanged canonical gate and same-input replay.
All five matrices now close successfully with stable inputs and empty error lists:
held-read (24 fixtures / 48 latency cases), memory (72 fixtures / 288 model-
latency measurements), FP (72 / 288), and AGI (12 / 48). These are **180 cold
fixtures**, plus **640 branch fixtures**, on this new model, not inherited
passes. Memory/FP/AGI take 24.04 / 14.85 / 5.75 seconds; the branch matrix takes
181.30 seconds. All **820 fixtures pass**. The 16 focused fault cases also
pass on both models (32 measurements), with unchanged inputs and no errors.
Canonical verification closes **FAIL** in 406.01 seconds, native exit 2. Its
functional verdict lines match the parent, and all 20 complete cycle streams
are identical; no masks, goldens or bands change. Same-input replay passes all
108 programs / 80,800 complete records in 73.08 seconds, without truncating or
normalizing the records. The independent
[complete-trace auditor](../verif/l1/audit_mc_branch_residency_core.py) then
reopens all directed traces: **438,312 architectural and 438,312 cycle records**,
including **117,436 paired V retirements**. It closes successfully under
`ventium-mc-branch-residency-audit-oct11.service`, invocation
`b5d2170701aa4d5aa671776ce33bf538`. Audit SHA-256:
`e0ef32a3d4822ec72d404ef746f962ee8ff3cab17f5410bd4e5baff89d4f156c`.
The check controller retains exit 1 because canonical verification is still
red; successful parent/candidate comparisons are not substituted for that gate.

The [matching PC builder](build_mc_branch_residency_soc.py) closes successfully
after that audit, native exit 0 in **33.79 seconds**, with stable inputs. It
changes only this header relative to the combined PC model,
preserves 154 defines and the posted-16 platform, requires equality of all 102
shared RTL sources, and creates a new model-local harness with a checked local
generated-header dependency. Its 98 inherited platform structural warnings
are unchanged; this is not a clean full-SoC lint result. Service
`ventium-mc-branch-residency-soc-oct11.service`, invocation
`9da092664eae4d0690bcf7f22a82558c`; full-PC model SHA-256:
`e9d4065fb8cdd5273eaf81ace062c3f7eb793cc2b019f63e72db0191d3fb3561`.
The
[FPGA exporter](freeze_mc_branch_residency_rk_candidate.py) likewise requires
only the exact header delta from the combined 190-payload manifest. Six
exporter tests pass, including profile drift, fast-feature removal, unreviewed
source changes and input replacement rejection. The exact new model's short
CoreMark seed run is live under `ventium-v-carry-cm10-branch-oct11.service`,
invocation `529ad6850c444af2b8bf28e0aa270d14`; export is also running. No
CoreMark, export/lint or frequency result is claimed before its run closes.

The export subsequently closes successfully. An independent source audit
rehashes **300,773 inputs**, verifies all **102 shared core sources**, and
confirms the single expected header change. The manifest retains 190 payloads,
117 filelist units, 49 include edges, 156 hardware defines, full P5 L1s and
the posted-16 transport. Manifest SHA-256:
`f607808a87e112b4629bfe86596d9515fede0e72eff3c7980a0088555f712f48`.
Strict CPU-hierarchy lint then passes all six hard structural classes in
**3.78 seconds**, native exit 0 with stable inputs; invocation
`cd3d860b440745a3a7c8d5497052dfed`. This is neither full-SoC lint nor timing/
hardware qualification. The short CoreMark run remains live; the synthesis
queue has not launched Vivado yet.

The owned queue is prepared to run the same short CoreMark seeds, source
export/audit and strict CPU lint, then one guarded synthesis with a **45-minute
limit**, followed by original-clock timing analysis. The earlier combined run
reached technology mapping but exhausted its 30-minute allowance; only the
time allowance changes. The 8 GiB RAM / 6 GiB swap caps, 13 GiB combined early
stop, 2 GiB host reserve, 6 GiB disk admission and 4 GiB disk stop remain.
The queue does not launch routing or deploy an image. No frequency gain is
assumed from the source-level changes.

### Disk recovery for this run

**2,423,344,551 bytes (2.26 GiB)** of net space was recovered with checked,
lossless `tar --zstd` archives. These contain generated compiler products from
closed builds and `.rtd` intermediates from the timed-out combined synthesis.
Every selected file was checked against protected source/evidence pins;
archives were compared before loose copies were unlinked. Sources, binaries,
headers, model-local harness objects, traces, logs and completed checkpoints
remain. The canonical `verif/tb/obj_dir` was not touched. Recovery commands and
hashes are under `closed-product-recovery/` and `inactive-compiler-recovery/`
in this candidate's evidence root. This is recoverable storage cleanup, not
removal of test evidence or an acceptance waiver.

The canonical gate remains red; the full standard suite and physical Win95/
Quake acceptance remain open. The best completed unplaced post-synthesis
estimate is **26.01118 MHz**, below the **40 MHz** requirement.

Gameplay baseline: **0.51030715 total U+V IPC**, model `2b4d7a48…`, cycles
**1,200,065,237–1,300,065,237**. Both newer timing candidates are unmeasured in
gameplay; isolated equivalence does not supply a gameplay result.
