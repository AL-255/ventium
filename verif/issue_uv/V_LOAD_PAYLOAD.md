# Registered-owner selector for paired V-load writeback

October 13, 2026. **Native selector leaf checked; not a qualified core,
synthesized candidate, or board image.** The ongoing current-tag synthesis
does not contain this proposal.

## Measured motivation and exact change

The data-size parent's independently audited worst unplaced path is 97 logic
levels, **35.830735605 MHz**, from EIP to GPR writeback. Its late segment runs
through immediate paired-load validity/acceptance and the GPR data mux. See
[`DATA_SIZE_CONE.md`](../segment_extent/DATA_SIZE_CONE.md). This is an observed
mapped path, not proof that every source-level combination is reachable.

`core_gpr_wb.svh` chooses immediate versus held V-load data using the late
`pipe_v_pair_now_accept` event. In the existing RAW-V, non-dual-prime profile:

- The core already asserts that `pipe_mem_v_hit_q` requires an active U read.
- Immediate V acceptance explicitly requires `!pipe_mem_active_q`.
- The V-load write arm consumes data only when held or immediate acceptance
  is true. All enclosing commit, pair, load-kind and precise-fault guards remain.

Therefore the registered `pipe_mem_v_hit_q` bit can select held data versus
immediate data. `prepare_v_load_payload.py` changes only that data argument and
adds simulation-only overlap/equality witnesses next to the existing ownership
assertion. Other macro profiles retain the original selector. No new feature
flag, state, port, cycle, write enable, response consumption or fault rule is
introduced. The existing width/high-byte merge and U-before-V trace logic are
unchanged. Both exact parent files are hash checked; reversal recovers their
original bytes, and drift/reapplication are rejected.

This does **not** remove L1's separate invalid-data zeroing, the V-load branch's
acceptance guard, or architectural commit qualification. Synthesis may absorb
the change. No frequency, area, IPC or throughput improvement is claimed.

## Checks so far

Three Python tests pass: exact source reversal/drift rejection, exhaustive
abstract Boolean owner controls, and extraction of the actual source selectors.
The first extraction test incorrectly treated a comma inside a comment as an
argument separator; it failed and was corrected to inspect code, not comments.
The RTL transformation did not change in response to that checker failure.

`v_load_payload_contract.smt2` gives two UNSAT results (owner exclusivity and
all-bit consumed-payload equivalence) and four SAT counterexamples (missing
owner invariant, unused-payload equality, held-only and immediate-only
mutations). These are **manually stated binary contracts**, not automatic
SystemVerilog formal elaboration or an inductive proof of core state ownership.

`run_v_load_payload_leaf.py` has now closed eight native source-extracted
Icarus profiles: **55,296 consumed-payload comparisons**, plus four separately
compiled negative variants that fail as required. Each profile enumerates
64 control combinations with 256 seeded data vectors. The changed profile
checks **2,048 held / 512 immediate** consumed values and explicitly excludes
6,144 invalid-owner vectors; it does not claim those excluded states pass.
Other profiles preserve the original selector, including overlapping owners.
The four negative variants force held-only, immediate-only, inverted selection
and an invalid extension of the optimization to another owner model.

Evidence root:
`/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.
The first run, `v-load-payload-leaf-r1`, closes in **1.55 s**, peak RAM
42,012,672 bytes, no swap/OOM. It records CPU18 on the controller, not each
native child, so it is not sufficient actual-child-affinity evidence.

`run_v_load_payload_observed.py` repeats the unchanged corpus while recording
each native command's argv, executable, PID/start time, cgroup, CPU affinity,
exit and reaping. **R2 repeats coverage; it adds no unique test cases.**
It closes in **1.47 s**, peak RAM **34,357,248 bytes**, no swap/OOM. The
independent `audit_v_load_payload_leaf.py` checks all 12 input pins, the exact
two-file proposal, profile counts, compiled mutations, SMT answers and
**26 actual native commands on CPU18**. An extra Python-controller observation
does not count: the auditor requires the exact native argv for every command.
Owner `ventium-v-load-payload-leaf-oct13-r2.service`, invocation
`25004064b4da440cbcd81d71e1d83180`, is terminal, MainPID 0 / exit 0.

| R2 evidence | SHA-256 |
| --- | --- |
| `closed.json` | `6dbc35aa4548cbcc7bd53a9981e40a9cc9c060d022646680cd48e78cbfc8b3d7` |
| `audit.json` | `55826128d28ff75f915f669a74f6f07c34b70d8b6a07f8a61ad9a82c5b5f10fa` |

Unlike a C++/full-core build, this tiny leaf was allowed alongside the separately
capped Vivado family on CPU18, with 512 MiB/no swap and a >4 GiB available-host-
RAM admission reserve. This relaxes only the earlier blanket ban on concurrent
compiler activity; Vivado's limits and exclusive-family rule are unchanged.
Binary leaf checks do not qualify arbitrary X/Z states or whole-core retirement.

The next steps are a source-matched whole-core build,
directed immediate/held byte and dword loads including snoop/abort/reset cases,
same-input architectural/cycle comparisons, the differential gates, and only
then a separately identified hardware transfer/timing comparison if warranted
by the current synthesis result. The full standard suite and physical FPGA
Win95/Quake validation remain required. No existing failure is waived.

Parent source root:
`/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X/window-current-core-r1/candidate`.
Use external `TMPDIR`, `PYTHONDONTWRITEBYTECODE=1`, and a fresh output directory.
The leaf runner requires CPU18, a 512 MiB/no-swap systemd owner, more than 5 GiB
free scratch disk and more than 4 GiB available host RAM; each native command
has a 20 s process-group timeout plus 2 s forced-cleanup grace.

Candidate gameplay IPC is **unmeasured**. The older verified simulation baseline
is **0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this proposal and is not an FPGA or
Doom measurement.
