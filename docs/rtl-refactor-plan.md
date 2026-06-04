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
