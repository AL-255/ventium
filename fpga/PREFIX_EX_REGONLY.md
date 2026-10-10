# Register-only prefix admission factoring — 2026-10-10

Status: **private candidate; no new FPGA image or measured timing gain**.
The 40 MHz implementation failed routing, not functional simulation. This work
targets its reported writeback-to-prefix-admission cone without reducing U/V
issue, disabling the fast pipeline, adding a stall, or changing cache geometry.
See [the failed-route evidence](ZERO_C1_EXPORT.md).

## Change and equivalence argument

`VEN_P54_PREFIX_EX_SYSTEM` already requires `!d_mem_read && !d_mem_write`
at `p54_prefix_ex_take`. Its shared shape predicate nevertheless consults the
current `gpr_we` bus to detect a successor EA dependency. That check matters in
the legacy profile, which can accept a memory successor, but cannot affect
an admitted system-profile successor.

The exact-source recipe [prepare-prefix-ex-regonly.py](../verif/fe_pipe/prepare-prefix-ex-regonly.py)
replaces that shape term with `!d_mem_read` **only in the system profile**.
The legacy branch and every final admission check remain unchanged, including
IF-aware interrupts, debug, cache/snoop identity, page/CS bounds and FP owners.

Let `M` denote a memory read and `H` the old EA/writeback hazard permission.
The relevant old system expression is `!M && (!M || H)`; the new expression
is `!M && !M`. Both equal `!M`. The intermediate shape has no other consumer
outside its own include; the build script checks this source-closure property.
This is combinational factoring, not a new execution policy or a timing waiver.

Netlist names are shared across RTL expressions after flattening. Therefore
passing equivalence checks does **not** establish shorter hardware paths or
reduced congestion. Inspect the actual LUT cone and compare synthesis before
another implementation run.
[report_prefix_fanin.tcl](report_prefix_fanin.tcl) reads the failed checkpoint
and dumps the relevant LUT equations/connectivity without modifying it.

### Actual mapped dependency confirmed, 21:50 UTC

The read-only diagnostic closed natively with exit 0 in 90.99 seconds, with
all original inputs unchanged. In the failed checkpoint, synthesis/optimization
**did retain the redundant EA/writeback dependency**:

- `p54_prefix_ex_retire_pc_valid_q_i_56` is a LUT6 with
  `INIT=64'h0000077707770777`. Its I0/I1 pair is `d_addr_mask[7]` and the
  combinational output of `p54_prior_write_mask[7]_i_2` (not that register's Q).
  Other inputs similarly combine address-mask bits with writeback enables.
- Its output drives `_i_27/I5`; that LUT also takes `d_mem_read`,
  `d_addr_mask_known`, and another writeback/address-mask pair. `_i_27` then
  feeds `_i_8`, `_i_3`, `_i_1`, and the actual `p54_prefix_ex_take` net.
- The retained critical path reaches this cone through REP continuation,
  `gpr_we12841_out`, and the combinational GPR-writeback mask logic. Thus this
  is not merely a misleading "prior mask" register name in the timing report.

Root: `/home/yukidama/external/tmp/ventium-prefix-fanin.z3aM8Ivo`;
`reports/logic_fanin.rpt` SHA-256
`377f3f8a937cdcbaabc51a708b54427882e1b330c5bc456af3c983ca61a6e03a`.
The sole Vivado family exited; no checkpoint, constraints, or image changed.
This confirms the target dependency in the **old** mapped design, not the
new design's resource count, routing success, or Fmax.

## Verification performed

Root: `/home/yukidama/external/tmp/ventium-prefix-regonly.IBpNH05Q`.

- Parent directed model: `f74dd76ba78e2a09db09be0a69c58f08164b19f1d38782c6050492a34d27e9e5`.
- Candidate directed model: `16b7e9e2c2c12a9ce3e15c8f5c8fabe0f8e61df92d3e57fa205b66ee8d7b4410`.
- Exactly one RTL delta: `rtl/core/core_prefix_ex_chain.svh` in the fresh private
  source bundle. Existing frozen inputs and the dirty production checkout are
  untouched. Defines are identical; the private C++ host object is compiled
  against this model's generated headers, not reused through VPATH.
- Five fail-closed recipe tests pass. The native actual-include miter passes
  **331,850 checks in each of the legacy/system profiles (663,700 total)**,
  including all write-mask/address-mask combinations, memory/known-EA states,
  prefix bytes, page/CS boundaries, IF/INTR, guards, retirement-PC ownership
  and reset. Two deliberately wrong variants fail the equivalence assertion:
  deleting the legacy EA guard and admitting a system memory successor.
- **384 cold paged system cases**: six instruction patterns × flat/relocated
  context × 32 byte offsets. Each runs both models, both AXI latencies (0/7),
  and both functional/cycle observations. All QEMU architectural comparisons
  pass. Complete A/B architectural records and retirement-cycle streams match;
  all 768 paired clock comparisons have **zero delta**. Actual V retirement
  and prefix overlap are required; no record removal or new field mask.
- The existing 1,216-case direct-FP-load regression has zero RTL/native
  expectation mismatches. Its 928 QEMU mismatches are retained, not relabelled
  correctness passes; that oracle discrepancy predates this change.
- The unchanged canonical `make verify` remains **FAIL**: native make exit 2,
  7/108 functional passes, and 12/19 scored cycle kernels failing their bands.
  All 20 complete RTL cycle streams are identical to the parent, including the
  informational kernel. No goldens, masks, or cycle bands were changed.

The independent `audit.json` rehashed **6,209 source/input pins**, reread the
full A/B streams, and confirmed **167,424 identical architectural records**,
**29,952 actual V retirements**, and **5,096 overlap admissions**. It separately
checked the native child scope and the outer controller identities, all reaped.
Audit SHA-256:
`3fa7672ce382ede734f4b67ea87f88c91c9be6b5dff9c669a0f0fbd8229940f8`.

Reproduction entry points are
[the leaf/mutation gate](../verif/fe_pipe/run-prefix-ex-regonly.py),
[the exact-parent builder](../verif/fe_pipe/build-prefix-ex-regonly.py), and
[the cold-system A/B gate](../verif/fe_pipe/run-prefix-ex-regonly-system.py).
Use the normal bounded build scope, external `TMPDIR`, and unique output
directories. Native commands, input hashes and closures are retained in the
root above. The latter gate deliberately requires identical feature profiles
and every retirement cycle unchanged; it is not the earlier overlap-enable
experiment that expected fewer clocks.

## Still required

Inspect the synthesized cone, measure the structural effect, then qualify an
exact-source FPGA export before any new place/route or deployment. The full
standard suite and physical Quake/Win95 acceptance are not inherited by this
directed model.

Latest verified gameplay baseline remains **0.49366456 U+V retirement-event
IPC**, older full-PC model `bfb867f7`, cycles
**5,200,065,237–5,300,065,237**. The newer full-PC candidate `2b4d7a48` and this
directed factoring derivative have no verified gameplay measurement. The last
physical image remains `fe9f539d`, approximately 40 MHz, **0.167990963 primary/U
event IPC**, completed timedemo **3.36 FPS**; total U+V is unavailable on that ABI.
