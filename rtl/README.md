# Ventium RTL (`rtl/`) — block map

Synthesizable SystemVerilog replica of the Intel Pentium (P5/P54C). Through
M1–M5 + M5B the real integer/x87/pipeline logic was built up; **R1** then
*modularized* it (docs/rtl-refactor-plan.md): the former monolith
`core/intcore.sv` was decomposed into packages + leaf modules and renamed to
`core/core.sv` (module `core`), which now just **wires the extracted blocks and
runs the pipeline FSM + retire**. The empty PLAN §6 stub files remain as the
future home of the fully-pipelined block versions.

Compile order is pinned by the **explicit filelist `rtl/ventium.f`** (packages
first, then modules) — it replaced the old `$(wildcard rtl/**)` glob, whose
alphabetical ordering put packages after their consumers. `verif/tb/Makefile`
and the lint target both build via `-f rtl/ventium.f`.

Contracts this directory implements (read these, not this README, when in doubt):
- [`../docs/rtl-interface.md`](../docs/rtl-interface.md) — top ports (§1, §3),
  the DPI `vtm_retire`/`vtm_retire_x87`/`vtm_retire_cycle` imports (§2).
- [`../docs/trace-format.md`](../docs/trace-format.md) — the `.vtrace` fields
  the retire callback feeds (§2.2).
- [`../docs/rtl-refactor-plan.md`](../docs/rtl-refactor-plan.md) — the R1
  decomposition table + interface design (the source for the block map below).
- [`../PLAN.md`](../PLAN.md) — §2 (target µarch + parameters), §6 (block
  decomposition), §7 (milestones).

## Build / lint

The authoritative build is the Verilator testbench (`verif/tb/`, driven by
`make verify` from the repo root). A standalone lint (no DPI symbol) is:

```sh
cd /home/yukidama/github/ventium/rtl && \
verilator --lint-only -Wall -Wno-UNUSED \
  -sv --top-module ventium_top -f ventium.f +define+VTM_NO_DPI
```

The packages supply all shared types/functions; `import …::*` in each module
resolves them (no `` `include `` needed). It also lints with the DPI import
present (drop `+define+VTM_NO_DPI`); the testbench phase does the full
`--cc --exe` build that binds the C++ `vtm_retire`.

### Warning waivers (kept minimal)
- `-Wno-UNUSED` — the un-pipelined PLAN §6 block stubs (and a few intentionally
  partial signals in `core.sv`) carry documented-but-unwired ports; the
  command-line waiver covers them.
- `-Wno-DECLFILENAME` — **dropped** in R1. Every file now satisfies
  *file name == module/package name* (one module per file), so the waiver is no
  longer needed.

No other waivers are required.

## Block map → PLAN §6 + reference pages

`ventium_top` instantiates the spine `core` plus the PLAN §6 block stubs. The
real datapath lives in `core/core.sv` and the leaf modules/packages extracted
from it in R1; the remaining stubs go live (as pipelined blocks) at M2S+.

**STATUS legend:** `REAL` = carries live logic today; `stub` = empty block file
(ports tied off, awaiting its milestone).

### Packages (shared types + pure functions, compiled first)
| File | Contents | STATUS |
|---|---|---|
| `ventium_pkg.sv` | arch-state types + DPI imports | REAL |
| `core/ventium_alu_pkg.sv` | ALU-op encoding + ALU/flags/shift/rotate pure functions (`alu_result`, `flags_next`, `shrot_*`, `shld_*`, `wmask`/`sbit`/`sbit2`/`parity8`) | REAL (R1) |
| `core/ventium_decode_pkg.sv` | decode enums (`kind_e`/`smk_e`/`st_e`/`ctk_e`/`fxop_e`), the `fpd_t` decoded-uop struct + `FK_*`, and pure helpers `mfl`/`is_prefix`/`cond_true` | REAL (R1) |
| `fpu/fpu_x87_pkg.sv` | 80-bit floatx80 datapath | REAL (M3) |

### Modules
| File | PLAN §6 block | Key reference (page) | STATUS |
|---|---|---|---|
| `ventium_top.sv` | top: ports + single DPI retire point; wires `core` + the §6 stubs | rtl-interface.md §1,§2,§3 | REAL |
| `core/core.sv` | the integer/pipeline **spine** — pipeline FSM (PF/D1/D2/EX/WB), AGI interlock, retire; instantiates `decode`×2 + `issue_uv`; uses the ALU/decode packages. Renamed from `intcore.sv` in R1. | docs/m2-isa-spec.md; m4-pipeline-spec.md; m5 | REAL (M1–M5; renamed R1) |
| `core/decode.sv` | §6.2 fast-path variable-length decoder (MOV/ALU/INC-DEC/LEA/load/shift/Jcc + cycle-mode x87 reg-form whitelist) → `fpd_t`. Extracted from the spine in R1. | Dev. Manual Vol.1 ch.2; A&A p.3 Fig.5 | REAL (R1) |
| `core/issue_uv.sv` | §6.3 U/V pairing checker (AP-500 classes) → `pair_ok`. Extracted from the spine in R1. | AP-500 241799; Agner Fog; docs/ap500-pairing-table.md | REAL (R1) |
| `core/fetch.sv` | §6.1 Front end (prefetch) | Alpert & Avnon p.2–3 | stub |
| `core/bpred_btb.sv` | §6.1 Front end (BTB+predictor) | Alpert & Avnon p.3 Fig.6 | stub |
| `core/exec_int.sv` | §6.3 ALU/shift/mul/div/flags/bypass datapath | Dev. Manual Vol.1 ch.2; Agner Fog tables | stub |
| `core/regfile.sv` | §6.3 integer GPR file + partial-reg + bypass | IA-32 SDM Vol.1 (243190) ch.3 | stub |
| `fpu/fpu_top.sv` | §6.6 x87 FPU (scoreboard around `fpu_x87_pkg`) | Alpert & Avnon p.6–8 Fig.8/9 | stub |
| `mem/icache.sv` | §6.1 L1 I-cache (8K/2-way/32B) | Alpert & Avnon p.5 | stub |
| `mem/dcache.sv` | §6.5 L1 D-cache (banked, MESI, dual-port) | Alpert & Avnon p.5 Fig.7; AP-500 | stub |
| `mem/tlb.sv` | §6.4 Address gen / I+D TLBs / paging | IA-32 SDM Vol.3 (243192) ch.3 | stub |
| `bus/biu.sv` | §6.10 64-bit bus interface unit (the SVA-verified `biu_p5` lives under `verif/bus/`) | Datasheet 241997-010 | stub |
| `ucode/ucode_rom.sv` | §6.7 Microcode engine | Dev. Manual Vol.1 ch.2; Agner Fog | stub |
| `sys/sys_state.sv` | §6.9 system state + §6.8 exc pipeline | IA-32 SDM Vol.3 (243192); Dev. Manual Vol.3 | stub |

Note: the M1–M5 integer/x87/cache/FP **timing** all live inside `core/core.sv`
today (the spine). The `exec_int`/`regfile`/`fpu_top`/`icache`/`dcache` modules
above are still stubs — extracting the corresponding sub-blocks out of the spine
into them was deferred in R1 as too entangled with the FSM (the gate is the
authority; partial modularization that stays green is the rule).

(§6.8 Interrupt/exception pipeline is folded into `sys/sys_state.sv`'s scope and
may split into its own file when it grows.)

## Retire / DPI point (what `ventium_top` actually does)

`ventium_top` owns the top port list (rtl-interface.md §1,§3) and the **single
DPI retire point** (§2). The `core` spine raises `retire_valid` for one clock per
committed instruction with the post-commit architectural state (plus the paired
`retire2_*` for a dual-issued V instruction and the x87/cycle side-channels);
`ventium_top` translates each into `vtm_retire` / `vtm_retire_x87` /
`vtm_retire_cycle` calls, maintaining the monotonic retire counter `n`.

The memory port group (`mem_*`, rtl-interface.md §3) carries the live fetch /
load / store traffic the spine drives.

## Integration notes

- **DPI guard.** The `vtm_retire` import lives in `ventium_pkg.sv`, fenced by
  `` `ifndef VTM_NO_DPI ``; the call site in `ventium_top.sv` is fenced the same
  way. Standalone lint defines `VTM_NO_DPI`; the TB build leaves it undefined and
  links a C++ `extern "C" void vtm_retire(...)` matching the §2 signature
  (verified here against the exact arg widths: `longint→uint64_t`,
  `int→uint32_t`, `shortint→uint16_t`).
- **Parameters for the TB.** Override on the `ventium_top` instance:
  `ENTRY` (fetch base = manifest `entry`), `STEP`, `N_RETIRE` (trace length).
- **x87 retire.** `vtm_retire_x87` (rtl-interface.md §2, trace-format.md §2.2)
  is declared in `ventium_pkg.sv` and called from `ventium_top.sv` (live since
  M3); `vtm_retire_cycle` carries the M4 pipe/paired cycle attribution.
- **Compile via the filelist.** Build with `-f rtl/ventium.f` (packages before
  modules); do not glob `rtl/**` and do not compile files individually. The
  packages form the shared compilation unit the modules import.
