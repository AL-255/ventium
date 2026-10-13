# Registered-owner selector for paired V-load writeback

October 13, 2026. **Prepared private proposal; not a qualified core, synthesized
candidate, or board image.** The ongoing current-tag synthesis is unchanged.

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

`run_v_load_payload_leaf.py` is prepared for eight native source-extracted
Icarus profiles and four separately compiled negative variants. It has not run
yet: no compiler is launched alongside the current Vivado family. The planned
leaf explicitly excludes invalid ownership combinations only in the qualified
profile; other profiles must retain old behavior even for overlapping owners.
Binary leaf checks do not qualify arbitrary X/Z states or whole-core retirement.

The next steps are native leaf closure, a source-matched whole-core build,
directed immediate/held byte and dword loads including snoop/abort/reset cases,
same-input architectural/cycle comparisons, the differential gates, and only
then a separately identified hardware transfer/timing comparison if warranted
by the current synthesis result. The full standard suite and physical FPGA
Win95/Quake validation remain required. No existing failure is waived.

Parent source root:
`/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X/window-current-core-r1/candidate`.
Use external `TMPDIR`, `PYTHONDONTWRITEBYTECODE=1`, and a fresh output directory.
The leaf runner requires CPU18, a 512 MiB/no-swap systemd owner, more than 5 GiB
free scratch disk and no live Vivado; each native command is capped at 20 s.

Candidate gameplay IPC is **unmeasured**. The older verified simulation baseline
is **0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this proposal and is not an FPGA or
Doom measurement.
