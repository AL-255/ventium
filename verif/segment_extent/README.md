# Segment-Extent & Fast-Memory Admission Timing Harnesses (`verif/segment_extent/`)

`verif/segment_extent/` holds SMT/SystemVerilog equivalence miters and whole-core regression runners for three combinational critical-path cuts on `rtl/core/core.sv`'s segment-limit and fast-memory admission cones.

> **RTL Invariant (`AGENTS.md`):** Always preserve the canonical translatable address generator and keep segment identity in its separate combinational block — never reintroduce the `cur_seg_rel → acc_usr → perm_fault → bus` combinational loop (`-Werror-UNOPTFLAT`).

## Harnesses in This Directory

| Variant | Scripts & Leaf TB | Equivalence Scope |
| --- | --- | --- |
| **1. 9-bit Extent Distance Compare** | `prepare.py`, `tb_extent.sv`, `run_leaf.py`, `run_regression.py`, `test_prepare.py` | Replaces `({1'b0, offset} + zext(count) - 33'd1) > zext(limit)` with precomputed address/limit distance compared against the late 8-bit `count` (`QF_BV` `unsat` across full 32-bit `offset`/`limit` × 8-bit `count`, including 256-byte blocks, 32-bit wrap, and zero-count behavior; `2,852,512` SV vectors + 2 negative mutations). |
| **2. Decoupled `cur_data_size` Cone** | `prepare_data_size.py`, `tb_data_size.sv`, `run_data_size_leaf.py`, `run_data_size_checks.py`, `test_data_size.py` | Taps `cur_data_size` before the `S_FETCH`-only demand-size override (`S_FETCH` is unconditionally code, never data) so late instruction-fetch length decode leaves the data-segment limit cone while preserving whole-object x87 environment overrides (`UNSAT` cofactor proof + `362,144` SV vectors + 3 negative mutations). |
| **3. Parallel Fast-Load Segment Eligibility** | `prepare_fast_segment.py`, `tb_fast_segment.sv`, `run_fast_segment_leaf.py`, `run_fast_segment_system.py`, `test_fast_segment.py` | Reduces normal-data attributes and full-limit eligibility across all segment descriptors in parallel before selecting by segment ID, and reads `DS` directly on the `DS`-only bounded fast-load branch (`UNSAT` cofactor proof + `1,202,816` SV checks across 4 profiles + 30 cold `U/V + fast-pipe` system runs at AXI delays `0/7/31`). |

## Timing Disposition & Current Hardware Sign-Off (`c0e3fe43`)

During October 2026 unplaced synthesis exploration, these source-level cuts shaved local logic levels (e.g., `100 → 98` levels, `34.496 → 35.475 MHz` unplaced estimate on Variant 3) while revealing that `u_icache` broadcast fanout (`pf_fill_addr`) and unretimed front-end/decode mux cones dominated routed delay. Combining RTL fanout replication (`pf_fill_addr_rep[0..3]`), narrow `ic_res_line_base` muxing, global synthesis retiming, and `opt_design -muxf_remap` + `AlternateCLBRouting` achieved full **40 MHz post-route static timing sign-off** on **`main` release image `c0e3fe43`** (**`40.264133 MHz`**, `WNS = +0.164 ns`, `WHS = +0.010 ns`, `0` `>=85%` congestion hotspots), with verified physical Quake gameplay IPC of **`0.515778001` total U+V** (`0.397847833` primary/U-only) across cycles `28,696,827,616–32,989,404,795`.

## Running Recipe & Leaf Checks

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B -m unittest discover -s verif/segment_extent -p 'test_*.py'
```

Run any native Verilator leaf or core build inside `tools/build_scope.sh` with `VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator` and fresh output directories under `/home/yukidama/external/tmp`.
