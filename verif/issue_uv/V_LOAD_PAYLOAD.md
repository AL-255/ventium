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

## Whole-core preparation and cold-fixture qualification

`build_v_load_payload_core.py` has prepared `v-load-payload-core-r1` from the
tested current-tag parent model
`737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7`.
Exactly **two of 195 source files** differ; their bytes match the native leaf's
proposal. All **152 definitions**, assertions, board single-fill setting and
32-job compiler command remain unchanged. The host has a unique private
basename; the inherited native builder checks its own generated header/object.
Three preparation/profile tests pass, including rejection of dual-prime,
missing fast relocation, wrong AXI policy, missing assertions and reduced jobs.
**No compiler has launched:** the live Vivado family retains exclusive access
to the heavy-build budget.

`run_v_load_payload_system.py` adds cold paged fixtures with distinct per-word
data and nonzero preserved EBX bytes. They cover dword, low-byte and high-byte
V loads, both flat and relocated clients, instruction offsets 0/31, and AXI
latencies 0/7. Ordinary dependent reads seed the immediate window; other-line
reads exercise the held response. Same-bank, unaligned dword and 16-bit-memory
controls must not pair. No saved state, hierarchical write or reduced mode is
used. Three fixture/comparison-preservation tests pass.

The **unchanged parent** ran as both control and candidate to qualify the
fixtures before testing the proposal. `v-load-system-baseline-r1` closes in
**40.55 s**, **32 cold fixtures / 256 native simulator executions**. All
**128 full architectural comparisons with QEMU, 30,208 records**, pass;
complete cycle traces also agree. Duplicating the parent is explicitly
`fixture_only=true`, **not an A/B implementation pass or new RTL acceptance**.
Per named candidate lane (not doubled for its identical control):

| Load shape | Paired V retirements | Immediate acceptance witnesses |
| --- | ---: | ---: |
| Same-line dword | 128 | 120 |
| Same-line low byte | 128 | 120 |
| Same-line high byte | 128 | 120 |
| Other-line dword | 128 | 0 |
| Other-line high byte | 128 | 0 |
| Same-bank / split dword / word controls | 0 each | 0 each |

`audit_v_load_payload_system.py` independently rechecks the native logs, full
architectural comparisons, complete per-instruction clocks, 32 image hashes,
all source pins and **256 actual simulator children with CPU12 affinity**.
The source-matched owner is terminal, MainPID 0 / exit 0, invocation
`ad43cbe07b364a0ba039cb53fa75cb72`. Peak memory is **118,493,184 bytes**;
the 1 GiB/no-swap, one-CPU, 540-second owner had no OOM. This bounded run used
only tiny guest assembly and existing binaries alongside Vivado, not another
RTL or C++ build. Baseline closure hash:
`d5ace6c40e358f67f558139b19f47550e65c5efb8279a27247fb3bf4aeb4c9c4`;
independent audit hash:
`9144ba25bb7bcd72d12505801842e39499ae27f425707adb1ce6d47b6c8ea3c7`.

The proposed selector still needs this whole-core replay, precise fault and
live-owner snoop/abort/reset coverage, general gates and timing measurement.
Cold resets here do not establish reset-during-outstanding-response coverage.

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
