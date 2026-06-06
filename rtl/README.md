# Ventium RTL (`rtl/`) — block map

Synthesizable SystemVerilog replica of the Intel Pentium (P5/P54C). Through
M1–M5 + M5B the real integer/x87/pipeline/cache/bus logic was built up inside a
single spine; the codebase was then *modularized* in two behaviour-preserving
passes (docs/rtl-refactor-plan.md):

- **R1** decomposed the former monolith `core/intcore.sv` into shared packages +
  the `decode` / `issue_uv` leaf modules, and renamed the monolith to
  `core/core.sv` (module `core`).
- **R2** lifted further leaf modules out of the spine *verbatim*: the BTB
  (`bpred_btb.sv`), the L1 cache arrays + the D-cache timing model
  (`icache.sv`, `dcache_timing.sv`), the split TLB arrays (`tlb.sv`), the x87
  architectural state file (`fpu_top.sv`), and the system / x87 helper packages.

Everything listed below is a **real file that carries live logic** — there are no
empty stub files. What is *not* yet a separate module still lives in the
`core.sv` spine (see the note after the table). M6 layered selectable silicon
errata into the datapath, M8 added the SoC integration top + peripheral models,
and M8.5 added the optional radix-4 SRT divider (all in existing files).

Two pinned filelists drive the builds (packages first, then modules):
`rtl/ventium.f` (core + `ventium_top`) and `rtl/ventium_soc.f` (the SoC
integration top `ventium_soc`). They replaced the old `$(wildcard rtl/**)` glob,
whose alphabetical order put packages after their consumers. `verif/tb/Makefile`
and the lint target build via `-f rtl/ventium.f`.

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
- `-Wno-UNUSED` — a few intentionally partial signals in `core.sv` (and
  read-only array ports exposed by the R2 leaf modules back to the spine) carry
  documented-but-not-fully-consumed bits; the command-line waiver covers them.
- `-Wno-DECLFILENAME` — **dropped** in R1. Every file now satisfies
  *file name == module/package name* (one module per file), so the waiver is no
  longer needed.

No other waivers are required.

## Block map (what is actually in `rtl/`)

`ventium_top` instantiates the spine `core` plus the R2-extracted leaf modules;
`soc/ventium_soc.sv` is the alternative top that wraps the same `core` with the
PC-platform peripheral models. Every file below carries live logic.

### Packages (shared types + pure functions, compiled first)
| File | Contents |
|---|---|
| `ventium_pkg.sv` | shared architectural-state types + the DPI retire import |
| `core/ventium_alu_pkg.sv` | ALU-op encoding + ALU/flags/shift/rotate pure functions (`alu_result`, `flags_next`, `shrot_*`, `shld_*`, `wmask`/`sbit`/`sbit2`/`parity8`) — R1 |
| `core/ventium_decode_pkg.sv` | decode enums (`kind_e`/`smk_e`/`st_e`/`ctk_e`/`fxop_e`), the `fpd_t` decoded-uop struct + `FK_*`, helpers `mfl`/`is_prefix`/`cond_true` — R1 |
| `core/ventium_sys_pkg.sv` | system-mode pure helpers: GDT/LDT descriptor field extraction, segment type/attr predicates, the descriptor-load fault decision + IDT vector, the 32-bit TSS byte-offset tables, the addr-size ModR/M length helper — R2 |
| `core/ventium_x87_pkg.sv` | x87 instruction-level helpers wrapping `fpu_x87_pkg`: compare codes, NaN classifiers, the #IA/#ZE/#PE decision, FXAM/FCONST tables, mem-operand coercion, the masked-default arithmetic evaluator (`f_eval`) — R2 |
| `fpu/fpu_x87_pkg.sv` | the 80-bit `floatx80` datapath (`fx_add/mul/div/sqrt`, rounding, conversions) — M3; also the M6 FDIV/FIST errata models and the optional M8.5 radix-4 **SRT divider** (`fx_srt_div`) |

### Modules
| File | What it is | STATUS |
|---|---|---|
| `ventium_top.sv` | top: port list + the single DPI retire point; wires `core` + the leaf modules | REAL |
| `core/core.sv` | the integer/pipeline **spine** (~4.3k lines): the PF/D1/D2/EX/WB FSM, AGI interlock, the slow-path microsequencer, the 2-level page-table walk, the integer execution datapath + GPR file + bypass, the x87 scoreboard, and retire. Instantiates the leaf modules below. Renamed from `intcore.sv` in R1. | REAL (M1–M5) |
| `core/decode.sv` | fast-path variable-length decoder (MOV/ALU/INC-DEC/LEA/load/shift/Jcc + cycle-mode x87 reg-form whitelist) → `fpd_t` | REAL (R1) |
| `core/issue_uv.sv` | U/V pairing checker (AP-500 classes) → `pair_ok` | REAL (R1) |
| `core/bpred_btb.sv` | 256-entry, 4-way BTB + 2-bit/4-state predictor (arrays + lookup/update), accessed in D1 | REAL (R2) |
| `mem/icache.sv` | L1 I-cache arrays + line fill + LRU-touch (8 KB / 2-way / 32 B = 128 sets); arrays exposed read-only to the spine | REAL (R2) |
| `mem/dcache_timing.sv` | L1 D-cache **timing** model — tag/valid/LRU only (no data array; load data comes from the bus) so the spine knows *when* a load completes | REAL (R2) |
| `mem/tlb.sv` | split I/D TLB arrays (16-entry, direct-mapped) + lookup + fill-commit + CR3 flush; the page-table *walk* stays in the spine | REAL (R2) |
| `fpu/fpu_top.sv` | x87 architectural **state file** — `fpr[8]` 80-bit stack, `ftop`/`fctrl`/`fstat`/`fptag`, FNINIT reset, `st(i)` addressing (the datapath is `fpu_x87_pkg`, the sequencing is in the spine) | REAL (R2) |
| `bus/biu_p5.sv` | standalone pin-level 64-bit P5 external bus FSM (ADS#/BRDY#/NA#/KEN#/CACHE#/HITM#…, burst order); SVA-verified, imports nothing from `rtl/` | REAL (M5B) |
| `bus/biu.sv` | gated integration wrapper that routes core memory through `biu_p5` — **default-OFF** (the default datapath uses the M0 bus-functional model in the spine) | REAL (M5B-int, default-OFF) |

Reference pages per block: Pentium Dev. Manual Vol.1 (241428) ch.2–3, Alpert &
Avnon (IEEE Micro 1993), AP-500 (241799) + Agner Fog for timing/pairing, IA-32
SDM (243190/92) for the ISA/system semantics, Datasheet 241997-010 for the bus —
see `docs/sphinx/reference-library.rst`.

**Still inside the spine (no separate file yet).** The prefetch/instruction
buffer, the microcode/slow-path microsequencer, the integer execution datapath +
GPR register file + bypass network, the FPU scoreboard/sequencing, and the
page-table-walk FSM are all modeled inside `core/core.sv`. Extracting them was
deferred because they are too entangled with the pipeline FSM — the differential
gate, not the file boundary, is the authority, and partial modularization that
stays green is the rule.

### SoC integration (`rtl/soc/`, M8 — built via `rtl/ventium_soc.f`)
| File | What it is |
|---|---|
| `soc/ventium_soc.sv` | SoC top: wraps `core` (`soc_en=1`), the PMIO port decode, the A20 mask, and the interrupt wiring |
| `soc/ven_pic.sv` | 8259A PIC, cascaded master + slave (0x20/0x21, 0xA0/0xA1) |
| `soc/ven_pit.sv` | 8254 programmable interval timer (0x40–0x43) |
| `soc/ven_rtc.sv` | MC146818 RTC / CMOS (0x70/0x71) |
| `soc/ven_i8042.sv` | 8042 keyboard/mouse controller (0x60/0x64) |
| `soc/ven_port92.sv` | port-92 fast-A20 gate (0x92) |
| `soc/ven_vgaregs.sv` | VGA register file (0x3B0–0x3DF) |
| `soc/ven_acpipm.sv` | ACPI PM timer (0x608) |
| `soc/ven_ide.sv` | IDE/ATA channel model — instantiated twice: primary master disk (0x1F0/0x3F6) and secondary ATAPI CD-ROM (0x170/0x376) |

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
