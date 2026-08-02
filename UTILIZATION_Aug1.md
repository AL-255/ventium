# FPGA utilization and compactness review — August 1, 2026

## Executive summary

The utilization problem is LUT/CLB pressure inside the CPU, not the KV260 shell and not a shortage of registers, BRAM, or DSPs.

The latest deployable result recorded in `docs/fpga-synthesis.md` uses 94,712 of 117,120 LUTs (80.9%) but 98.3% of the device's CLBs. That is enough logical LUT headroom to look comfortable on paper, but almost no placement freedom remains. This explains why small front-end changes cause large routing/timing regressions.

The strongest findings are:

1. **Moving all x87 compute to the PS is the only already-measured large lever.** A retained all-PL-x87 routed checkpoint uses 107,837 LUTs; the companion `VEN_FP_PS_ALL` checkpoint uses 73,765. The 34,072-LUT difference is 29.1% of the whole part. These are close, not perfectly controlled, builds, but their project define lists and hierarchy make the conclusion unambiguous.
2. **The GPR commit interface is probably the largest PL-only structural opportunity.** `u_regfile` contains only eight 32-bit architectural registers, yet Vivado attributes 22,214–25,065 LUTs to it. The driver constructs eight independent 32-bit state/result muxes (`gpr_wd[8]`) and replays the entire FSM's write predicates. Replace this with two or three destination-addressed commit ports plus explicit rare bulk-commit modes.
3. **The BTB should be LUTRAM, not 7.7k resettable FFs plus 7.7k LUTs.** Its tags/counters do not need reset; only valid bits and replacement state do. Packed, replicated distributed-RAM read images can retain the two combinational prediction ports and one update lookup.
4. **Use the abundant BRAM to remove L1D LUTRAM, tag FFs, and 512-bit mux/capture paths.** The routed L1D costs 8,137 LUTs, 5,999 FFs, and 2,480 LUTRAMs while the device still has 104 unused BRAM tiles.
5. **Keep the uop cache.** A close no-uop/offloaded-x87 comparison shows that removing it adds about 7k LUTs and 529 CLBs. Its 40-BRAM implementation is inefficiently wide and can be compacted later, but BRAM is not the limiting resource.
6. **`VEN_CACHE_HALF` does not currently halve the functional L1D.** `ventium_top` does not pass a smaller `L1_SETS` to `ventium_l1_axi`, and `ven_l1d` hard-codes seven index bits and a 20-bit tag anyway. The L1D must first be made genuinely parametric; simply overriding the parameter would be incorrect.

For a PL-only design, I would implement the BTB memory conversion first, then prototype the compact GPR commit bus. Together they expose enough measured footprint to recover the roughly 10–15k LUT/CLB margin the K26 needs. If PS x87 offload is acceptable, `VEN_FP_PS_ALL` is the immediate fit solution and the PL work becomes margin/reliability improvement rather than a fit emergency.

## Scope and evidence quality

This review used the working tree at `219c124` on branch `ao486-mister-sim`. The tree was heavily modified while fixes were being implemented, so line numbers and some implementation details may move. No product RTL was changed by this review.

A fresh reproduction of the latest deployment was not possible from this checkout because these recorded paths are absent:

- `rtl/soc/`
- `fpga/scripts/`
- `fpga/build/kv260_soc_impl_linux_40/`

The analysis therefore uses three kinds of evidence:

- the latest deployment figures recorded in `docs/fpga-synthesis.md`;
- retained routed checkpoints and their project define lists under `fpga/build/`;
- the current RTL structures that explain the retained hierarchical utilization.

I reopened the retained routed DCPs with Vivado 2025.2 and ran `report_utilization -hierarchical -hierarchical_depth 14`. Hierarchical LUT counts are attribution, not guaranteed isolated savings: Vivado can absorb upstream mux logic into a child and combine LUTs across boundaries. Recommendations below label measured footprint separately from estimated savings.

## Baselines

| Build | LUTs | FFs | BRAM tiles | DSPs | CLB occupancy | Notes |
|---|---:|---:|---:|---:|---:|---|
| Latest documented deployable | 94,712 (80.9%) | 31,208 | 40 | 31 | 98.3% | Routed at 40 MHz, WNS +0.104 ns, WHS +0.008 ns; checkpoint absent from this checkout |
| Retained all-PL x87 | 107,837 (92.1%) | 31,987 | 40 | 32 | 14,612 / 14,640 (99.81%) | `kv260_soc_impldosqfix`; all iterative PL engines, no `VEN_FP_PS_ALL` |
| Retained PS-all-x87 | 73,765 (63.0%) | 30,527 | 40 | 16 | 12,963 / 14,640 (88.55%) | `kv260_soc_impl_v86fix`; `VEN_FP_PS_ALL` + `VEN_FPTRAP` |
| Retained PS-all-x87, no uop cache | 80,736 (68.9%) | 28,277 | 8 | 16 | 13,492 / 14,640 (92.16%) | `kv260_soc_impluc0`; same main stack, without `VEN_UOPCACHE` |

The all-PL and PS-all checkpoints are not a strict one-source-revision A/B: small unrelated hierarchy differences are visible. The project files do, however, confirm the intended configuration split. The 34,072-LUT top-level difference is consistent with the explicit FPU blocks plus the x87 logic absorbed into the core spine.

The latest documented deployable has 22,408 nominal LUTs free, but 98.3% CLB occupancy means that most of those LUT sites are not in placeable/routable locations for the remaining logic. A useful target is **below about 85k LUTs and below 90% CLB occupancy**, not merely “under 117,120 LUTs.”

## Where the routed area goes

The detailed hierarchy below is from the retained 107,837-LUT all-PL checkpoint.

| Instance | LUTs | FFs | LUTRAM | BRAM36 | DSP | Interpretation |
|---|---:|---:|---:|---:|---:|---|
| Entire design | 107,837 | 31,987 | 2,748 | 40 | 32 | K26 top |
| `ventium_top` | 105,059 | 29,022 | 2,480 | 40 | 31 | CPU plus L1/AXI |
| `core` | 96,810 | 22,774 | 0 | 40 | 31 | 89.8% of top LUTs |
| Core spine, ungrouped | 23,570 | 6,392 | 0 | 0 | 15 | FSM/decode/execute/commit logic |
| `u_regfile` | 22,214 | 329 | 0 | 0 | 0 | Mostly absorbed write-data muxes, not register storage |
| `u_fpu_state` | 16,574 | 768 | 0 | 0 | 0 | x87 state plus combinational helpers |
| `u_fpu_wb` | 2,506 | 0 | 0 | 0 | 16 | Deferred arithmetic/rounding commit |
| `u_srt_div` | 4,846 | 726 | 0 | 0 | 0 | Iterative FP divide/remainder/sqrt support |
| BCD engines | 892 | 445 | 0 | 0 | 0 | `u_bcd` + `u_bcd2fp` |
| `u_icache` | 9,329 | 2,946 | 0 | 0 | 0 | Mostly tag/valid/LRU metadata in this uop-cache build |
| `u_uopcache` | 8,185 | 1,896 | 0 | 40 | 0 | Predecode walker and very-wide two-copy store |
| `u_bpred_btb` | 7,665 | 7,700 | 0 | 0 | 0 | Resettable FF arrays and two async queries |
| `u_l1d` | 8,137 | 5,999 | 2,480 | 0 | 0 | Full-line async LUTRAM, tag FFs, wide captured window |
| AXI master within L1/AXI | 113 | 185 | 0 | 0 | 0 | Not a useful optimization target |
| Everything outside `ventium_top` | 2,778 | 2,965 | 268 | 0 | 1 | SmartConnect, control, sysmon, fan, wrapper |

The external shell is not the problem. Even deleting all of it would not solve an all-PL-x87 fit, whereas changes inside the core can.

## Prioritized compactness work

### P0 — choose the x87 placement policy explicitly

The retained near-pair measures the top-level effect of `VEN_FP_PS_ALL`:

- 107,837 to 73,765 LUTs: **−34,072 LUTs**;
- 32 to 16 DSPs;
- explicit all-PL FPU submodules account for 24,818 LUTs in the high build;
- another 18,368-LUT high/offload difference appears in the ungrouped core spine, partly offset by unrelated mapping differences elsewhere.

`VEN_FP_PS_ALL` retains the architectural x87 state in PL and sends compute/conversion work to the A53 service path. It is the fastest route to a robust K26 fit if the deployed PS software and latency model are acceptable. It is not a generic standalone-core solution and adds a PS/PL availability dependency.

If full offload is unacceptable, add a **selective PS trap mask** and remove selected PL engines. The current optional transcendental tie-offs are unsafe as a general product mechanism: comments in `core.sv` state that executing a compiled-out opcode wedges `S_TRSC_BUSY` forever. Route an absent operation to the existing trap protocol instead. Current evidence says:

- `VEN_TRANS_NO_TRIG` is unsafe for Quake; trigonometric operations were observed;
- `VEN_TRANS_NO_FYL2X` is unsafe for Quake; logarithm operations were observed;
- `VEN_TRANS_NO_F2XM1` is the lowest-risk target, but remains an ISA compatibility loss unless it traps to PS.

The retained 107,837-LUT checkpoint did not enable `VEN_TRANSCENDENTAL`, so the 34k measured delta should not be interpreted as including every current transcendental engine.

### P1 — replace the eight independent GPR write-data cones

Evidence:

- `regfile.sv` contains eight 32-bit registers: 256 architectural data bits.
- Its interface is `gpr_we[7:0]` plus eight independent `gpr_wd[31:0]` buses.
- `core.sv` has one broad combinational writeback case, and the included `core_gpr_wb.svh` is 773 lines.
- The driver explicitly says it re-derives all FSM write gates and recomputes write values.
- Vivado attributes 22,214 LUTs to `u_regfile` in the all-PL build and 25,065 in the offloaded build.

This structure asks synthesis to build a separate state/op/result mux for every bit of every architectural register. Most clocks need zero, one, or two writes, but the interface is sized as eight unrelated write-data networks.

Recommended representation:

```systemverilog
typedef struct packed {
  logic        valid;
  logic [2:0]  dst;
  logic [31:0] data;
  logic [3:0]  byte_en;
} gpr_commit_t;
```

Use two normal commit ports, or three if the string-fault rollback must remain single-cycle. Add small explicit modes for the genuinely wide cases:

- dual issue, XCHG/XADD, MUL/DIV, and stack destination+ESP: two ports;
- page-fault string rollback: up to EDI/ESI/ECX, so three ports or a serialized recovery state;
- CPUID: four registers, either a two-cycle commit or a dedicated CPUID bulk mode;
- RSM and task switch: all eight registers, either four two-port cycles or a dedicated bulk restore mux from `rsm_gpr[]`/`tsw_gpr[]`.

A dedicated rare bulk input does not recreate the current problem: it adds one small alternative at each register D input, while normal results share two or three data muxes.

For both compactness and correctness, execution should produce canonical commit bundles once. The state side-effect logic and GPR update should consume the same predicates/results instead of maintaining a second mirrored case tree. Recent hoisting of multiply/divide/shift results already follows this direction.

**Expected impact:** high, but unmeasured. The 22–25k hierarchy attribution is the footprint exposed to optimization, not a promise that all of it disappears. Prototype this as an OOC/full-context A/B before undertaking the rare bulk-state sequencing.

**Risk:** high. Same-cycle multiwrite priority, partial-register merge behavior, real-mode SP wrapping, fault rollback, and last-write-wins semantics must remain exact.

### P1 — convert BTB tags/counters to replicated LUTRAM

Current geometry in `bpred_btb.sv` is 64 sets × 4 ways with:

- 26-bit tag per entry;
- 2-bit saturating counter per entry;
- valid bit per entry;
- 2-bit replacement pointer per set;
- two combinational prediction queries and one resolve/update lookup.

The reset loop clears tags and counters even though invalid entries make those values irrelevant. That prevents normal RAM inference and produces 7,700 FFs plus 7,665 LUTs.

Recommended structure:

1. Pack the four ways' tags and counters into a word indexed by set.
2. Keep valid bits and replacement pointers in resettable FFs.
3. Do **not** reset tag/counter storage.
4. Use replicated distributed-RAM images for U lookup, V lookup, and resolve lookup; broadcast the single update to every image.
5. Preserve the current read-before-write prediction semantics and the optional registered resolve input under `VEN_BTB_PIPE`.

A 64-deep LUTRAM maps naturally into LUT6 memories. Even three replicas of roughly 112 data bits per set are far smaller than the current resettable multiport register/mux structure. BRAM is another option if a synchronous predictor stage is acceptable, but LUTRAM should preserve the current combinational contract with less pipeline risk.

**Expected impact:** several thousand LUTs and most of 7.7k FFs are plausible; measure rather than treating the primitive-bit estimate as a routed result.

**Risk:** medium. Prediction contents affect performance/cycle fidelity, not architectural correctness, but same-edge update visibility and counter saturation must stay exact.

### P1 — make L1D narrow, synchronous, and genuinely parametric

The functional L1D currently uses:

- `logic [255:0] dc_line [L1_SETS*2]` with asynchronous distributed-RAM reads;
- two whole-line reads to make a 512-bit `{next,current}` window;
- a 512-bit registered `rd_window_q`;
- resettable 20-bit tag arrays;
- a variable 32-bit byte slice from the 512-bit window.

This maps to 2,480 LUTRAMs, 5,657 logic LUTs, and 5,999 FFs. Much of the FF count is the 5,120 tag bits plus valid/LRU and the captured window.

Recommended changes:

1. Store 32- or 64-bit words in banked true-dual-port BRAM instead of 256-bit asynchronous lines.
2. Read only the aligned word pair needed for an unaligned dword and merge it with a small 64-bit aligner.
3. Pipeline tag/hit with the address; the external contract already uses a registered read-serve path.
4. Stop resetting tag data. Reset only `dc_val`; a tag is ignored when its valid bit is clear.
5. Pack tags into addressed LUTRAM or BRAM rather than 5,120 individually resettable FFs.
6. Preserve the newly added fill-poison, snoop, flush, and address-match protections. Compactness work must not restore stale-data races.

The K26 has enough headroom for an implementation using several additional BRAMs. The exact bank count depends on whether fill/write and the two read words must operate concurrently, but even an 8-BRAM design is inexpensive here.

#### `VEN_CACHE_HALF` hole

The current half-cache flag does not shrink this functional L1D:

- `ventium_top.sv` instantiates `ventium_l1_axi` without an `L1_SETS` override;
- `ventium_l1_axi` defaults `L1_SETS=128` and passes that to `ven_l1d`;
- `ven_l1d` declares an `L1_SETS` parameter but hard-codes `logic [6:0] set_*`, address bits `[11:5]`, and tags `[31:12]`.

Do not simply pass 64 today; that would permit indices outside the smaller array and use the wrong tag split. First derive `IDXW=$clog2(L1_SETS)` and `TAGW=32-5-IDXW` throughout `ven_l1d`, then wire the production geometry deliberately. The earlier documented `VEN_CACHE_HALF` saving of only 2.7% is consistent with the functional L1D not participating in this configuration.

**Expected impact:** moving data and tags can exchange several thousand LUT/FF resources for a small number of BRAMs. Halving the corrected L1D is an additional capacity/performance tradeoff, not the primary structural win.

**Risk:** medium-high because of coherence and read-during-write behavior. Run the Aug-1 L1 race tests and a gate-level/board BRAM collision test.

### P1/P2 — compact the I-cache metadata interface

In the routed uop-cache build, `u_icache` uses 9,329 LUTs and 2,946 FFs but no BRAM. The 2,946 FF count almost exactly matches the 64-set, two-way tag/valid/age metadata; the raw line store is dead in the normal uop-cache path and was optimized away.

The current module exports every tag, valid bit, and victim entry to the core. `core.sv` repeatedly inlines `ic_present()` and `ic_hit_way()` for `flin`, the next line, instruction endpoints, and redirect targets. This inhibits compact addressed-memory inference and duplicates lookup cones.

Recommended changes:

- move hit/way/victim queries into `icache` and expose a finite set of addressed query ports;
- compute `{present,way}` once for each distinct front-end address and reuse it;
- stop resetting tags; clear valid bits only;
- store tag words in replicated LUTRAM if same-cycle queries must remain combinational;
- in `VEN_UOPCACHE` builds, consider one shared tag/valid owner for I-cache residency and predecode residency instead of parallel metadata structures, while retaining a separate predecode-valid bit for mode/default-size invalidation.

Do not remove or merge the three current invalidation events merely to save ports. The concurrent DMA/SMC and cross-line invalidations are correctness requirements; replicate narrow metadata memories or queue updates safely.

**Expected impact:** potentially several thousand LUTs/FFs, but the exact query count and update replication need an A/B synth.

**Risk:** medium-high because tag timing is tied to registered uop-cache reads and recent read-during-write fixes.

### P2 — compress the uop-cache record and storage shape

The uop cache is beneficial overall. In the retained PS-all builds:

- without it: 80,736 LUTs, 8 BRAM, 13,492 CLBs;
- with it: 73,765 LUTs, 40 BRAM, 12,963 CLBs.

That is a near-pair saving of 6,971 LUTs and 529 CLBs, consistent with the stronger OOC result already documented (93,883 to 79,442 LUTs). Do not go back to the live twelve-way byte-window decoder.

The current storage is nevertheless BRAM-width inefficient:

- `fpd_t` is 162 bits in the reviewed tree;
- eight slots make a 1,296-bit word;
- the boundary map adds 128 bits;
- the entire 1,424-bit line record is replicated for A and B reads;
- the nominal payload is about 365 Kbits, but its width/port shape consumes 40 RAMB36 tiles.

The record contains fields that can be derived after read:

- `reads`, `writes`, and `addr_mask` are three 8-bit one-hot masks derived from encoded register indices and operation form;
- `fp_lat` and `fp_occ` are fixed tables indexed by FP operation/role;
- `br_taken` is already recomputed from `cc` and live EFLAGS;
- many boolean format fields are mutually exclusive;
- `imm` and `rel` do not need independent 32-bit payloads for most formats.

Recommended direction:

1. Define a compact stored token, then expand it once after slot selection.
2. Store slots as narrow addressed entries instead of reading all eight 162-bit slots and selecting with an 8:1 wide mux, if one extra front-end stage is acceptable.
3. Bank consecutive slots or provide two narrow read ports for U/V.
4. Write each slot/boundary progressively during the walker and assert line-valid only at completion, eliminating the 1,424-bit `wbuf_slots`/`wbuf_bmap` FF buffer.

This work should optimize LUT routing first and BRAM second. A narrower token reduces both the BRAM lane count and the wide slot-select fabric. An extra stage must be evaluated against branch redirect timing and P5 cycle fidelity.

### P2 — share PL x87 normalize/round/pack resources

If x87 must remain in PL, the measured footprint says to optimize the arithmetic architecture rather than individual boolean expressions:

- `u_fpu_state`: 16,574 LUTs;
- `u_fpu_wb`: 2,506 LUTs and 16 DSPs;
- `u_srt_div`: 4,846 LUTs;
- BCD conversion engines: 892 LUTs;
- additional x87 selection/conversion logic is absorbed into the 23,570-LUT core spine.

The current `fpu_writeback` already contains a good example: under `VEN_SRT_ITER`, `f_eval_s1` feeds one shared `f_eval_s2` round/pack stage instead of building separate add and multiply round cones. Extend that principle:

- one sequential normalize/round/pack pipe shared by slow arithmetic, fast deferred commit, and conversions;
- register an operation/result carrier instead of recomputing broad combinational results in the writeback state mux;
- use DSPs freely for multiplies—only 31 of 1,248 DSPs are used in the latest deployment;
- send rare conversions/transcendentals through the PS trap path rather than instantiating every engine or wedging on a tied-off engine.

This is a larger microarchitectural project and requires SoftFloat differential testing for every rounding mode and exception flag. It is lower risk to use selective PS traps first.

### P2/P3 — contain front-end decode growth

The synthesis history records that the real-mode/16-bit F3 decode work made the uop-cache front-end route about 3.5 ns slower and moved the deployable clock from 50 to 40 MHz. The current tree has a 439-line fast decoder, a 1,706-line slow decoder, and a 162-bit stored uop record.

With `VEN_UOPCACHE`, the two live U/V byte decoders are correctly compiled out; one decoder remains in the fill walker. Keep that property. Compactness options are:

- encode common 16/32-bit behavior once, rather than duplicating full-width arms;
- move rare system/segment forms to the existing slow FSM when their fast execution is not required for the target performance;
- use small opcode/group ROMs or staged microdecode for the fill walker;
- expand one-hot hazard masks after the stored token is selected;
- synthesize system-fast support as a separately measurable feature flag so its LUT/performance cost remains visible.

This is likely relevant to the most recent utilization growth, but no current checkpoint is present to isolate the new decode changes. Obtain a before/after hierarchy report before deleting functionality.

## Lower-priority or counterproductive work

- **Do not optimize the AXI master first.** It is 113 LUTs; the entire non-Ventium shell is only 2,778 LUTs.
- **Do not remove `VEN_UOPCACHE`.** It saves LUTs/CLBs despite consuming 32 additional BRAMs in the retained near-pair.
- **Keep `VEN_FP_PIPE2` and `VEN_FE_PIPE`.** The documented results show that they improve routability; `VEN_FP_PIPE2` also reduced LUTs by 1.6% while adding only 273 FFs.
- **Do not spend early effort reducing DSP count.** The core uses only about 2.5% of available DSPs. Sharing integer multipliers may help routing, but it does not address the scarce resource.
- **`VEN_DBG_CORE` is not the LUT root cause.** A controlled routed `rtlirq`/`rtlirqdbg` pair adds only 125 LUTs, 628 FFs, and 1.5 BRAM tiles. It does reduce WNS from +0.510 to +0.216 ns, so keep it off in production, but disabling it will not recover the required LUT margin.
- **Further cache-capacity reduction alone is not enough.** The historical half-cache experiment saved only 2.7% LUTs and did not improve Fmax. Fix the storage/query structure first.
- **The redundant cycle-only D-cache timing model is already removed under `VEN_L1_AXI`.** The documented saving was roughly 4.4k cells; do not accidentally re-enable it in the SoC build.

## Recommended implementation order

1. Restore or regenerate the exact latest full-SoC build recipe and archive its define list, DCP, flat utilization, hierarchical utilization, RAM utilization, and timing summary.
2. Prototype the BTB LUTRAM conversion. It is self-contained, has a clear 7.7k-LUT/FF measured target, and need not change architectural state.
3. Prototype a two/three-port GPR commit bundle while retaining dedicated CPUID/RSM/task-switch bulk modes. Measure before changing rare-state cycle sequencing.
4. Convert L1D tags first (valid-only reset), then data/serve to banked synchronous BRAM. Make geometry parametric before wiring a half-size option.
5. Collapse I-cache metadata queries and remove tag resets without weakening the new snoop/fill protections.
6. Compact `fpd_t` storage and the uop-cache slot read only after the first four changes establish enough placement margin.
7. If PL x87 is still too large, add selective safe PS trapping; otherwise use `VEN_FP_PS_ALL` for the K26 deployment.

## Validation and acceptance criteria

Run one isolated change per build. For every candidate, record both resource totals and hierarchy because synthesis may move logic across module boundaries.

| Gate | What must hold |
|---|---|
| Functional differential suite | All current `make verify` architectural and cycle gates pass |
| GPR directed tests | Dual issue, XCHG/XADD, MUL/DIV, stack+ESP, partial 8/16-bit merges, CPUID, RSM, task switch, string fault rollback |
| BTB tests | Same pre-edge lookup/update behavior, saturation, allocation, round-robin victim, and prediction/cycle bands |
| Cache tests | All Aug-1 snoop/fill/flush/read-window races, SMC cross-line invalidation, unaligned reads/writes, BRAM read-during-write model |
| FPU tests | SoftFloat/QEMU differential tests for all RC modes, exception flags, stores/loads, transcendental and FPREM paths |
| Board workloads | SeaBIOS, FreeDOS, Win95, Quake, DMA/PS memory modification, and cold-line fetch stress |
| Implementation | 40 MHz WNS/WHS positive with no failing endpoints; no new critical warnings or RAM inference failures |
| Area target | Prefer <=85k LUTs and <=90% CLB occupancy on the full K26 SoC |

Useful reports for each A/B:

```tcl
report_utilization
report_utilization -hierarchical -hierarchical_depth 14
report_ram_utilization
report_timing_summary -max_paths 20
report_methodology
```

For RAM rewrites, inspect the primitive hierarchy as well as the headline BRAM count. Confirm that tag/data arrays became RAM primitives, that intended replicas remain distinct, and that Vivado did not declone or collapse read ports in a way that changes silicon read-during-write behavior.

## Bottom line

The design does not need broad peripheral trimming. It needs a few representation changes in the CPU:

- offload or share the x87 compute fabric;
- turn the BTB and cache tags into memories instead of resettable multiport registers;
- replace eight independent GPR write-data cones with a bounded commit interface;
- spend spare BRAM to eliminate wide asynchronous cache muxes;
- retain the uop cache but store a narrower token.

Those changes attack measured 7–25k-LUT structures rather than shaving hundreds of LUTs from the shell. The first practical goal is to recover at least 10k LUTs and bring CLB occupancy below 90%, which should improve both fit stability and timing reproducibility.
