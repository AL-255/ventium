# Register-only prefix admission factoring — 2026-10-10

Status: **synthesis-qualified private candidate; no new FPGA image**.
Register-only factoring reduces total mapped LUTs by 1.91% and shortens its
targeted unplaced path, but **does not improve overall worst-path timing**.
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

## Source-matched full-PC and FPGA derivative, 22:10 UTC

The full-PC build now closes as
`cf1b3b0bf30d35993c12f335c148dbf5c1ae90f09c0e26f3c2b22907263ab27c`,
under `/home/yukidama/external/tmp/ventium-prefix-regonly-soc.MMoWhswI`.
Its only RTL delta from `2b4d7a48` is the same prefix include. All 102 shared
RTL inputs match the directed model. The private host object/header ownership
was checked; all 154 simulator defines and posted-16 transport are unchanged.
The inherited 98 platform structural warnings remain debt, not lint passes.

Both original cold-boot **10-iteration** CoreMark disks complete with the
expected CRCs and actual V retirements. These are short correctness/clock
comparisons, **not duration-valid scores or standard-suite acceptance**:

| Seed | Parent clocks | Candidate clocks | Clock change | Actual V events |
| --- | ---: | ---: | ---: | ---: |
| Performance | 4,767,218 | 4,767,218 | 0 | 1,055,307 |
| Validation | 4,753,406 | 4,753,406 | 0 | 1,054,254 |

The independent audit rehashes 8,479 inputs, rereads both full consoles against
the original QEMU CRCs, verifies native argv/model/affinity, and confirms native
exit 0, reaped children and no OOM. Receipt: `coremark/audit.json`, SHA-256
`7e9e00ff7a2803c20e8efe7a6b66a067c61e7bdce2fabc6ec218ec620d907ee8`.
The parent's valid-duration scores are not transferred to this model.

[freeze_prefix_regonly_rk_candidate.py](freeze_prefix_regonly_rk_candidate.py)
exports exactly that model to
`/home/yukidama/external/tmp/ventium-prefix-regonly-fpga40.D6hb2tCk`.
Manifest SHA-256:
`5003847d311025e070fd12022b06251e62c9c50336962bc183ff179b3a903ee3`.
The independent export audit checks 8,641 pins, 190 payloads, all 156 hardware
defines, 117 filelist units and 49 include edges. Only the prefix header differs
from the parent export. Full P5 L1s, 256 KiB platform L2, posted-16 writes,
40 MHz core / 100 MHz PL clocks and UV/system/relocated fast paths are unchanged.
Four exporter tests cover exact payload/feature acceptance and drift rejection.

Strict lint of the exported CPU hierarchy passes with all six structural
warning classes treated as errors. This is **not full-SoC lint**, synthesis
acceptance, or a physical pass. Receipt:
`ventium-prefix-regonly-hw-lint.Cs41DX5l/closed.json`.

### Closed full synthesis, 22:18 UTC

The full synthesis closes under
`ventium-prefix-regonly-full-synth-oct10.service`, invocation
`0f2db8ef82af45fb8f715532c62898d1`, in
`ventium-prefix-regonly-full-synth.mcn9SQsB`. Native exit is 0 in **985.33 s**;
the independent audit rehashes **8,842 input pins**, verifies the native
156-definition/148-file compile, and checks the complete DCP archive. Only
the reviewed prefix header differs from the matched synthesis parent:

| Mapped resource | Parent | Prefix factoring | Change |
| --- | ---: | ---: | ---: |
| CLB LUTs | 195,617 | 191,887 | −3,730 (−1.91%) |
| Registers | 54,580 | 54,574 | −6 |
| BRAM tiles | 277.5 | 277.5 | 0 |
| DSPs | 47 | 47 | 0 |

These are whole-design synthesis counts, not isolated prefix-cone area or
placed/routed utilization. The native diagnostic summary retains **0 errors,
1 critical warning, 1,571 warnings**. The critical warning is the existing
vendor PS8 XDC `create_clock` reference to an unknown port/pin; it is not
suppressed. Actual core/PL clock objects and structural DRC are checked by
the separate read-only post-synthesis audit.

Audit SHA-256: `19ae9bfc1e73fc452ba83b9cdaa453e4bdc5bdac93b43a98ace30d2710c2639e`.
DCP SHA-256: `70a6835ba299d7723c7e21f2836b2eff1c3c0e9bf0a149dc2743a565e4e3d98a`.
No implementation or bitstream is produced. The bounded controller used
8 GiB RAM / 6 GiB swap, one Vivado family,
a 30-minute native deadline, and a 4 GiB runtime disk floor. Admission required
10 GiB free and more than twice the previous synthesis's measured 1.50 GiB
disk growth above that floor. Peak resident scope memory was 8,589,824,000
bytes with 622,108,672 bytes swap; no OOM, resource stop or source drift.
The entire synthesis family exited before launching the read-only comparison.
### Closed native timing/cone comparison, 22:28 UTC

The final read-only comparison is
`ventium-prefix-regonly-clock-r2.y0ASgQnb`, controller invocation
`c7747d91e8dc4b568ca8b16c23caceb4`. Native exit 0 in **231.86 s**, all **8,870
input pins unchanged**, no OOM/swap, peak scope memory 4,687,405,056 bytes.
The native clock objects are 40 MHz core / 100 MHz PL; there are zero black
boxes and zero errors from the MDRV-1/LUTLP-1 structural checks. This audit
does not start implementation, change constraints, or write a checkpoint.

| Synthesized-netlist observation | Parent | Prefix factoring |
| --- | ---: | ---: |
| Worst path through prefix admission, estimated MHz | 21.79 | 26.31 |
| Prefix-path logic levels | 159 | 130 |
| Overall worst core path, estimated MHz | 21.786 | 21.773 |
| Overall setup slack at 40 MHz | −20.902 ns | −20.929 ns |
| Worst hold slack | −0.101 ns | −0.101 ns |

These frequency figures are **unplaced path estimates**, neither routed
sign-off nor measured board frequencies. The local prefix-path improvement
does not justify claiming an overall Fmax improvement. The prefix cone's
transitive cell set shrinks from 82,383 to 68,689 objects; that reachability
includes shared logic and sequential boundaries, not area owned exclusively
by the prefix block. Remaining GPR/writeback dependencies exist elsewhere.

The first attempt, `ventium-prefix-regonly-clock-audit.9z6XQIvn`, is retained
as **native exit 1**, not a pass. It opened the parent synthesis DCP by itself,
which has no loaded project clock objects, and failed at the parent timing
report. The corrected attempt reads both original projects' synthesis runs and
original XDC constraints; it pins the parent project/generated XDC files and
independently reproduces the parent's earlier −20.902 ns result. No artificial
clock or timing exception was inserted to make the comparison pass.

Final audit SHA-256:
`db75fe03197eb3c49560c1a0b25dc1b03968cca52527efe1ffec9bd467d5d0e2`.
Both read-only Vivado families have exited. No new place/route has started.

## Remaining structural bottleneck and next repair

The new overall worst path is **160 logic levels**, from `eip_reg[0]` to
`pipe_mem_v_hit_q_reg/D`, with 45.718 ns estimated data delay. Its observed
sequence crosses prefix/dual decode, next-load EA/translation (`mc_prime_offer`),
L1 lookup and store-pair readiness, memory ACK, `mem_next_commit`, paired-bank
availability, and finally V-response owner capture. The mapped net names are
not module ownership, but the actual connectivity establishes the long
same-cycle control dependency. This is the next optimization target; the
prefix change has not solved the full FPGA timing/congestion problem.

Proposed repair: separate **prospective bank/tag availability** from
**irrevocable request acceptance and owner creation**, with explicit request
class/owner information if needed. In particular, inspect the late
`mc_capture_next`/`pair_prime_capture` contribution to the ready path shared by
fresh-U and primed-U requests. Preserve the original standalone pair contract
and the mandatory older-U acceptance before any V becomes an owner. This is
not yet implemented; simply dropping commit/snoop guards would be incorrect.

Required focused checks include legacy two-lane requests, fresh U/V loads,
primed U/V loads, U-store/V-load, same-bank conflicts, uncommitted predecessor,
held responses, under-fill access, invalidation/reset and stale-owner rejection.
Existing entry points include `verif/l1/tb_l1axi_pair_hit.sv`,
`verif/l1/tb_l1d_pair_store.sv`, `verif/l1/prime_under_ifill_leaf.svh`, and
`verif/issue_uv/tb_regmem_prime_pair.sv`. Extend them to require unchanged
accepted-edge/cycle behavior and no new owner on a rejected speculative offer.
Any core/cache change still requires the differential gates and full standard
suite, including physical-board validation; a new short gate cannot replace it.

## Still required

Repair the remaining memory-control critical path and evaluate its area/timing
before another place/route. The exact-source export above is source-qualified,
not a qualified bitstream. The full
standard suite and physical Quake/Win95 acceptance are not inherited by this
directed model.

Latest verified gameplay baseline is **0.50499738 U+V retirement-event
IPC**, older full-PC model `bfb867f7`, cycles
**5,600,065,237–5,700,065,237**; the 45 retained gameplay windows average
**0.500212996**. That model's original cold timedemo independently closes at
22:16 UTC: **969 frames / 125.3 seconds / 7.73 FPS at modeled 40 MHz**,
native exit 0, complete EOF, reaped process group, original disk/ROM/source
checks and fresh closed-FAT result. The results-console counters are explicitly
excluded from gameplay. This is not a new physical-board result.
Receipt: `ventium-store-admit-gameplay-r22.zeWN45tM/audit.json` under external
scratch. The newer full-PC candidates `2b4d7a48` and
`cf1b3b0b` have no verified gameplay measurement. The last
physical image remains `fe9f539d`, approximately 40 MHz, **0.167990963 primary/U
event IPC**, completed timedemo **3.36 FPS**; total U+V is unavailable on that ABI.
