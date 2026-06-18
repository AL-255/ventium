# RTL modularization plan — partitioning the monolith

## Problem

All the real integer/x87/pipeline logic accreted into a single file
**`rtl/core/intcore.sv` (~3400+ lines and growing)** across M1–M5, while the
`rtl/{core,mem,bus,ucode,sys}/*.sv` block files remain ~28-line empty stubs. One
file holding decode + types + helper functions + ALU/flags + register file +
pairing + the pipeline FSM + cache/FP timing is hard to read, review, and
maintain. `rtl/fpu/fpu_x87_pkg.sv` (581 lines, a clean package) already proves
the decomposition works — we extend that pattern to the whole core.

## Guiding principle: behavior-preserving, gate-protected, incremental

This is a **pure refactor — zero functional/cycle change.** Our differential
gates are the safety net that makes it safe:
> After **every** extraction step, `make m1 && make m2 && make m3 && make m4 &&
> make m5` must ALL stay green (func + cycle), and `verilator --lint-only` clean.
> Commit per step. **Never a big-bang rewrite.** If a step changes any gate
> result, revert that step — the refactor introduced a bug.

Extract in **lowest-coupling-first** order so risk ramps gradually.

## When to execute (NOT now)

Execute **after M5 lands and M5B is integrated** — `intcore.sv` is a moving
target while those workflows edit it. Refactoring concurrently would collide.
This doc is the plan; execution is a separate, post-M5 maintenance pass.

## Target decomposition (maps intcore.sv sections → files, per PLAN §6)

### Packages (types + pure functions — extract FIRST, near-zero risk)
| New file | Contents (moved from intcore.sv) |
|---|---|
| `rtl/ventium_pkg.sv` *(exists)* | arch state types + the DPI imports — keep |
| `rtl/core/ventium_decode_pkg.sv` | the uop/decoded-instruction **struct**, ALU-op enum (`ALU_ADD…ALU_NOT`), the micro-sequencer enums (`SM_*` stack, `ST_*` string), x87 decode enum; pure decode helpers `mfl()` (ModR/M field length), `is_prefix()`, `cond_true()` (Jcc tttn) |
| `rtl/core/ventium_alu_pkg.sv` | ALU result + EFLAGS computation as pure functions; width/flag helpers `wmask() sbit() sbit2() parity8()` |
| `rtl/fpu/fpu_x87_pkg.sv` *(exists)* | the 80-bit floatx80 datapath — keep |

Pure functions/types moved to a package and called in place are **bit-identical**
behavior — this alone removes a large chunk of `intcore.sv` with negligible risk.

### Leaf modules (clean combinational/stateful blocks — extract SECOND)
| Target file (today a stub) | Extracted block + interface |
|---|---|
| `rtl/core/decode.sv` | the variable-length decoder (prefix machine + opcode + ModR/M/SIB/disp/imm + x87 escape `D8–DF`). **IF** = `input [127:0] insn_bytes` → `output decoded_uop_t uop, output [3:0] len`. (~500–900 lines of the current decode `always_comb`.) |
| `rtl/core/issue_uv.sv` | the **pairing checker** (AP-500 classes per `docs/ap500-pairing-table.md`). **IF** = two `decoded_uop_t` + reg-write state → `pair_ok, v_pipe` assignment. |
| `rtl/core/exec_int.sv` | integer ALU + flags datapath (wraps `ventium_alu_pkg`). **IF** = `op, a, b, cf_in, width` → `result, flags`. Instantiated ×2 (U & V). |
| `rtl/core/regfile.sv` | GPR file + **partial-register** read/merge + bypass read ports. **IF** = read ports (with bypass), write ports (per pipe). |
| `rtl/core/bpred_btb.sv` | 256-entry/4-way BTB + 2-bit predictor (M4). **IF** = lookup(eip)→{pred_taken,target}, update(eip,taken,target). |
| `rtl/fpu/fpu_unit.sv` | x87 scoreboard + latency/throughput sequencing (M5), wrapping `fpu_x87_pkg` datapath + holding the stack/status/control/tag state. |
| `rtl/mem/icache.sv`, `rtl/mem/dcache.sv` | the M5 cache **timing** models (8 KB/2-way/32 B, LRU, miss penalty, D$ banks). **IF** = req → {data, ready, stall_cycles}. |
| `rtl/mem/tlb.sv`, `rtl/sys/sys_state.sv`, `rtl/ucode/ucode_rom.sv` | fill in when M2S adds paging/segmentation/SMM/microcode-ROM. |
| `rtl/bus/biu.sv` | replaced by the M5B `biu_p5` (see `docs/m5b-bus-spec.md`). |

### The spine (extract LAST / leave in place)
`rtl/core/intcore.sv` → rename to **`rtl/core/core.sv`** (or `pipeline.sv`): keeps
the PF/D1/D2/EX/WB pipeline FSM, the pipeline-stage registers, the AGI interlock,
the retire/DPI point, and **instantiates** decode / issue_uv / exec_int×2 /
regfile / bpred_btb / fpu_unit / icache / dcache. It becomes the readable
"how the blocks connect" file.

## Inter-module interface design

Define the cross-stage contracts as **packed structs in `ventium_decode_pkg`** so
modules connect by struct, not by dozens of loose signals:
- `decoded_uop_t` — {op, operand sources/dests, imm, width, mem/agu info, pairing
  class, is_branch/cc, fp fields, microcode kind, length}.
- `pipe_reg_t` — the D1→D2→EX→WB latched payload (uop + operands + results).
- regfile read/write port structs; cache req/resp structs.
Use SystemVerilog `interface`s only if a port group is shared by many modules
(e.g. the regfile bypass network) — otherwise structs keep Verilator-friendly.

## Build/convention changes

- **One module per file; file name = module name.** Packages as `*_pkg.sv`.
- Replace the testbench's `$(wildcard rtl/*.sv rtl/**/*.sv)` with an **explicit
  filelist** `rtl/ventium.f` listing packages **before** the modules that import
  them (deterministic compile order; avoids glob ordering surprises). Point
  `verif/tb/Makefile` and the lint target at `-f rtl/ventium.f`.
- Keep the documented lint waivers (`-Wno-DECLFILENAME -Wno-UNUSED`); after
  modularization, `-Wno-DECLFILENAME` may be droppable (file name now matches
  module) — try removing it.

## Step order (each step = its own commit, full gate suite green after)

1. **Packages — pure functions** (`mfl/is_prefix/cond_true/wmask/sbit/sbit2/
   parity8`, ALU+flags) into `ventium_decode_pkg` / `ventium_alu_pkg`. Lowest risk.
2. **Packages — types/enums** (uop struct, ALU/SM/ST/x87 enums) into the decode pkg.
3. Add `rtl/ventium.f` filelist + switch the build to it.
4. **`regfile.sv`** (GPR + partial-reg + bypass) — first stateful module out.
5. **`exec_int.sv`** (ALU datapath, ×2) using `ventium_alu_pkg`.
6. **`bpred_btb.sv`** (BTB + predictor).
7. **`icache.sv` / `dcache.sv`** (M5 timing models).
8. **`fpu_unit.sv`** (x87 scoreboard around `fpu_x87_pkg`).
9. **`decode.sv`** (the big variable-length decoder) — largest single extraction.
10. **`issue_uv.sv`** (pairing checker).
11. Rename the remaining spine `intcore.sv` → `core.sv`; it now just wires the
    blocks + runs the FSM/retire. Update `ventium_top.sv` instantiation + the filelist.
12. Final pass: drop now-unneeded lint waivers; re-run the full suite; update
    `rtl/README.md` block map.

## Tracking

Add a maintenance milestone **"R1 — RTL modularization"** to PROGRESS once M5 has
landed (don't edit PROGRESS now — M5's close-out owns it). R1 is non-functional;
its gate is "all of m1–m5 stay green across every extraction commit, lint clean."

## R3 — front-end / execution true-module split (post-R2)

R1/R2 extracted the clean leaf modules (decode fast-path, issue_uv, bpred_btb,
icache, dcache_timing, tlb, fpu_top, ven_idiv, …). R3 continues the split of the
remaining flat spine into the natural P5 functional blocks, **gate-protected**:
the refactor-time gate is `make verify`, but because `tx_fprem` is a known WIP
divergence at the time of R3, the per-step bar is a **byte-identical behaviour
fingerprint** (84 func PASS / 1 WIP FAIL tx_fprem / identical RTL cycle counts),
which is *stricter* than pass/fail (it catches in-tolerance cycle drift too).
Every step is `verilator --lint-only` clean and fingerprint-identical or it is
reverted.

### Extracted (true modules instantiated by core.sv)
| New file | Contents (moved VERBATIM from core.sv) | IF |
|---|---|---|
| `core/uv_common.sv` | shared U/V exec building blocks: the BCD/ASCII-adjust datapath (AAA/AAS/DAA/DAS/AAM/AAD) and the U→V EFLAGS forwarding that resolves a paired V branch | gpr[EAX]/imm/op/EFLAGS + u_pipe outputs → bcd_ax/bcd_flags, v_br_taken_eff |
| `core/u_pipe.sv` | the P5 **U-pipe** full ALU/shift datapath (M4 fast path) | u_d + pre-read operands + EFLAGS → u_alu/u_flags/u_sh/u_shm1/u_shcf |
| `core/v_pipe.sv` | the P5 **V-pipe** restricted ALU datapath | v_d + pre-read operands + EFLAGS → v_alu/v_flags |
| `core/decode_stages.sv` | the **slow-path instruction decoder** (~1400 lines): prefix machine, eff_opsize/eff_addr, sreg_idx, the variable-length combinational decoder | ibuf/gpr/EFLAGS/mode-state → the d_* decoded fields (115 ports) |
| `core/fpu_writeback.sv` | the **x87 FP write-driver** (~674-line combinational block): re-derives every x87 state mutation from the FSM/decode and drives the `fpu_top` write ports | state/decode-FP/fp-readback/engine-results → fp_we_*/fp_*_data (130 ports) |

`decode_stages` and `fpu_writeback` are the size wins (core.sv 6440 → ~4606,
-29%). Two in-module typedefs were promoted to `$unit` scope (top of core.sv,
before the module, next to each other) so the new modules' port/case types are
visible (compile order: core.sv precedes the new modules in rtl/ventium.f):
`sysop_e` (for decode_stages' `d_sysop` port) and `state_e` (the FSM enum, for
fpu_writeback's `state` input + `case(state)`). `fpu_writeback` is a clean
RELOCATION of an existing combinational driver (the fpu_top R2 pattern) — no new
logic and no duplication, unlike a would-be regfile driver.

### NOT extractable as a true module (structural, documented here so it is not re-attempted)
- **"microcoded / multi-cycle instructions"** — these are sequenced by the main
  `always_ff @(posedge clk)` FSM, which is the **single writer** of *all*
  architectural state (gpr, eip, eflags, segment regs/bases, CR0–4, dr*, the FSM
  state register, the x87 touch/seq state, the bus/memory request handshake). A
  standalone module would have to own that state — i.e. it would *be* the core, not
  a sub-block. The multi-cycle handlers are **already factored** into the raw-text
  includes `core_store_useq.svh` (PUSHA/POPA/strings/stack µops), `core_seg_ljmp.svh`
  (far CALL/JMP/RETF), `core_iret.svh`, `core_rmint.svh` (real-mode INT/IRET),
  `core_tss_priv.svh`/`core_tsw.svh` (TSS / hardware task switch), `core_smm.svh`
  (SMM), `core_int_deliver.svh` (PM interrupt gates), `core_walk.svh` (page-table
  walk) — these `\`included` chunks ARE the microcode, kept as netlist-identical
  text-includes because they are inseparable from the FSM that drives them.
- **regfile / prefetch buffer (ibuf)** — `gpr[]` is written from 145 NBA sites
  scattered across the FSM (12 core_*.svh + core.sv). A true module (gpr storage +
  reset + read outputs, written through combinational write ports) requires a
  spine-side combinational **write-driver that re-derives every write condition**
  (the same pattern as the existing ~1000-line x87 `fp_we_*` driver around the
  `fpu_top` instance). **Attempted and verified byte-identical**, but the only way
  to reproduce the 145 scattered NBA writes combinationally was to **duplicate the
  FSM control flow**: every `core_*.svh` case-arm split into a gpr-stripped half +
  a parallel `*_gw.svh` half (16 new files, ~3575 lines), with `core.sv` *growing*.
  That doubles the per-instruction edit surface and is a net maintainability loss
  for a 70-line module, so the attempt was **reverted**. Conclusion: `gpr` stays
  spine-resident, exactly like the architectural eflags/eip/segment/CR state and
  for the same single-writer-FSM reason. A true `regfile` module is only worth it
  if/when the core is re-architected so register writes flow through a small fixed
  set of commit ports (a pipeline rewrite, not a refactor).
