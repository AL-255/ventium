# Ventium RTL (`rtl/`) — Module & Filelist Guide

Synthesizable SystemVerilog reconstruction of the non-MMX Intel Pentium (**P5/P54C**, Family 5).

## Current Hardware & Branch Baseline (Nov 2026)

- **Target FPGA Platform:** **RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`), AMD Vivado **2025.2**.
- **Board-Qualified Release (`main`, image `c0e3fe43`, `161` defines):** Post-route static timing closed at **`40.264133 MHz`** (`WNS = +0.164 ns`, `WHS = +0.010 ns`, `0` `>=85%` congestion hotspots, `171,819` LUTs / `50.35%`, `30,703` CLBs / `71.97%`, `39,520` FFs, `277.5` BRAM tiles, `47` DSP48E2). Passes both standard CoreMark CRC seeds (`2.100128 / 2.106796 CM/MHz`), cold Windows 95 OSR2 GUI + shutdown, and cold DOS Quake `demo1` (`8.0 FPS`, `969` frames / `121.2 s`), with **`0.515778001` total U+V gameplay IPC** (`0.397847833` primary/U-only, including `REP`-element retirement) across interior cycles `28,696,827,616–32,989,404,795` (up from `2886d24c`'s `0.496499864` total U+V / `0.383002768` primary/U).
- **Development Branch (`experimental/uv-fast-ipc-apr`):** Holds ongoing core/cache/APR work and the Verilator/QEMU differential harness; post-freeze experimental RTL edits are unmeasured on physical gameplay unless re-qualified.

Authoritative interface and trace contracts:
- [`../docs/rtl-interface.md`](../docs/rtl-interface.md) — `ventium_top` ports, DPI-C retirement callbacks (`vtm_retire`, `vtm_retire_x87`, `vtm_retire_cycle`, `vtm_fp_async_event`), AXI replay, and cached-store policy.
- [`../docs/trace-format.md`](../docs/trace-format.md) — `.vtrace` JSON Lines functional, system, x87, and cycle record schemas.

---

## Ordered Filelists (Never Glob RTL)

Every SystemVerilog file follows **one module/package per file** (`*_pkg.sv` packages compiled before importing modules, raw `core_*.svh` state-machine fragments included only by `core.sv`). Never compile via `$(wildcard rtl/**)` globs:

| Filelist | Scope & Consumers |
| --- | --- |
| [`rtl/ventium.f`](ventium.f) | Standalone `ventium_top` core + caches + TLBs + `fp_shared/` + P5 `biu` (paths relative to `rtl/`). Used by `verif/tb/Makefile` and `verif/lint/run-lint-gate.sh` (`L1AXI_RTL` appends `ven_l1d.sv`, `ven_axi_master.sv`, `ventium_l1_axi.sv`, and `ven_cachemap.sv` when `+define+VEN_L1_AXI` is enabled). |
| [`../rtl_ven_core.f`](../rtl_ven_core.f) | Full `ao486`-integrated CPU + `fp_shared/` + banked `ven_l1d` + `ventium_l1_axi` + `ven_cachemap` + `ao486-sim/ven/ven_axi2avalon.sv` + `ven_ao486_shim.sv` (repo-root relative). Used by full-PC simulation (`ao486-sim/`) and RK-XCZU15EG-F Vivado synthesis (`fpga/`). |
| [`../rtl_ven_soc.f`](../rtl_ven_soc.f) | Vendored MiSTer PC/AT chipset & peripheral RTL (`3rd-party/ao486_MiSTer/`: `system.v`, PIC, PIT, DMA, RTC, PS/2, IDE, floppy, VGA, Sound Blaster 16 + OPL3, bypassed outer L2 wrapper). Note: the earlier standalone `rtl/soc/` toy peripheral directory has been retired in favor of this full PC/AT platform. |

---

## Lint & Verification

From the repository root, run the multi-profile lint gate (keeps `IMPLICIT`, `PINMISSING`, `UNDRIVEN`, `MULTIDRIVEN`, `LATCH`, and `UNOPTFLAT` fatal across default, L1-AXI, and FPGA define sets):

```sh
make lint   # runs bash verif/lint/run-lint-gate.sh
```

For a direct standalone Verilator lint check without DPI imports (maintainer host Verilator `/tools/verilator/v5.046/bin/verilator`):

```sh
cd /home/yukidama/github/ventium/rtl && \
/tools/verilator/v5.046/bin/verilator --lint-only -sv -Wall -Wno-UNUSED -Wno-fatal \
  -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN \
  -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
  --top-module ventium_top -f ventium.f +define+VTM_NO_DPI
```

---

## Block Map

### 1. Packages (Compiled First)

| File | Contents |
| --- | --- |
| `ventium_pkg.sv` | Architectural state types and DPI-C retirement imports (`vtm_retire`, `vtm_retire_x87`, `vtm_retire_cycle`, `vtm_fp_async_event`), guarded by `VTM_NO_DPI`. |
| `core/ventium_alu_pkg.sv` | Integer ALU/shift/rotate opcodes and pure result/EFLAGS helpers (`alu_result`, `flags_next`, `shrot_*`, `shld_*`, width/sign/parity helpers). |
| `core/ventium_decode_pkg.sv` | Decode enums (`kind_e`, `smk_e`, `st_e`, `ctk_e`, `fxop_e`), fast-path decoded uop struct `fpd_t` (`FK_*`), and ModR/M/condition helpers. |
| `core/ventium_sys_pkg.sv` | Protected-mode & paging pure helpers: GDT/LDT descriptor extraction, access/privilege classifiers, fault-vector selection, and 32-bit TSS offset tables. |
| `core/ventium_x87_pkg.sv` | Instruction-level x87 helpers wrapping `fpu_x87_pkg`: compare codes, NaN/FXAM classifiers, constant ROMs, and masked-exception evaluators. |
| `fpu/fpu_x87_pkg.sv` | 80-bit IEEE-754 `floatx80` arithmetic, rounding (`fx_round_pack_c1`), integer/FP/BCD conversions, and optional Pentium FDIV/FIST errata helpers. |

### 2. Top Wrapper & Integer Superscalar Core (`rtl/core/`)

| File | Architectural Role |
| --- | --- |
| `ventium_top.sv` | Core subsystem top: wires `core` to I/D caches, TLBs, `fp_shared`, optional `ventium_l1_axi` / `biu`, debug telemetry, and the single DPI retirement point. |
| `core/core.sv` + `core/core_*.svh` | Central 5-stage (`PF`/`D1`/`D2`/`EX`/`WB`) pipeline spine, `S_PIPE` protected-mode U+V fast path, split-page fragment engine, 2-level hardware page walker, and microsequencer. Includes 30 raw `core_*.svh` fragments (`core_fastpath.svh`, `core_fetch_decode.svh`, `core_exec.svh`, `core_gpr_wb.svh`, `core_bus_driver.svh`, `core_load.svh`, `core_store_useq.svh`, `core_seg_ljmp.svh`, `core_int_deliver.svh`, `core_iret.svh`, `core_tss_priv.svh`, `core_tsw.svh`, `core_walk.svh`, `core_smm.svh`, `core_fp_exec.svh`, `core_fp_async.svh`, `core_fenv.svh`, `core_io*.svh`, etc.). |
| `core/decode.sv` | Dual-slot fast-path instruction decoder producing `fpd_t` records for `S_PIPE` (`MOV`, `ALU`, `PUSH`/`POP`, `LEA`, `MOVZX`/`MOVSX`, shifts, branches, and fast x87 dispatch). |
| `core/decode_stages.sv` | Full variable-length prefix/ModR/M/SIB/system/x87 decoder feeding the multi-cycle execution states and complex instructions. |
| `core/issue_uv.sv` | Intel AP-500 dual-issue pairing checker (`UV`/`PU`/`PV`/`NP` classes, register RAW/WAW interlocks, ESP/EFLAGS special pairs). |
| `core/u_pipe.sv`, `core/v_pipe.sv`, `core/uv_common.sv` | Combinational U-pipe (full ALU/shift) and V-pipe (ALU/branch) integer datapaths, plus shared BCD/ASCII adjust (`DAA`/`DAS`/`AAA`/`AAS`/`AAM`/`AAD`) and U→V flag forwarding. |
| `core/regfile.sv` | Registered 32-bit GPR file (`EAX`–`EDI`) with dual boot-mode reset and per-register write enables driven from `core_gpr_wb.svh`. |
| `core/ven_p54_dual_agu.sv` | Dual U/V effective-address generators for `S_PIPE` memory operations. |
| `core/bpred_btb.sv` | Dual-ported **256-entry 4-way BTB** with 2-bit bimodal saturating counters (simultaneous fetch lookup and retire update). |
| `core/ven_idiv.sv` | Synthesizable iterative radix-2 integer `DIV`/`IDIV` engine (`+define+VEN_IDIV_ITER`). |
| `core/ven_frame_plan.sv` | Shared slot-offset planner for interrupt, trap, call-gate, and V86 stack frames (used identically by pre-probe, push, and `ESP` commit). |
| `core/fpu_writeback.sv` | Legacy combinational x87 state-mutation driver for `rtl/fpu/fpu_top.sv` when `VEN_FP_SHARED` is disabled. |

### 3. Memory, Caches, TLBs & AXI Subsystem (`rtl/mem/`, `rtl/northbridge/`)

| File | Architectural Role |
| --- | --- |
| `mem/icache.sv` | **8 KiB 2-way L1 I-Cache** (128 sets × 32 B lines, `8` RAMB36 data + LUTRAM tags under `VEN_IC_BRAM`), physical snoop tags (`ic_ptag`) for alias-safe self-modifying code/DMA invalidation, and fanout-replicated fill path. |
| `mem/ven_predecode_len.sv`, `mem/uopcache.sv` | Instruction-length predecoder and predecoded micro-op cache (`+define+VEN_UOPCACHE`). |
| `mem/ven_l1d.sv` | **8 KiB 2-way L1 D-Cache** (128 sets × 32 B lines, write-back/write-allocate + uncacheable byte-exact bypass, physical snoop invalidation, cached-store policy). |
| `mem/ven_p54_bank_arb.sv`, `mem/ven_p54_hit_return.sv`, `mem/ven_p54_bram_bank.sv`, `mem/ven_p54_bram_data.sv` | 8-way 32-bit word-interleaved P54C D-cache bank arbitration, dual-port U+V read hit return, and BRAM bank wrappers. |
| `mem/tlb_assoc.sv`, `mem/tlb.sv` | `tlb_assoc.sv` implements the deployed **64-entry 4-way D-TLB** (`VEN_DTLB_ASSOC_4WAY`) and **32-entry 4-way I-TLB** (`VEN_ITLB_ASSOC_4WAY`) with pseudo-LRU replacement; `tlb.sv` retains the 16-entry direct-mapped unit-TB baseline. |
| `mem/ventium_l1_axi.sv`, `mem/ven_axi_master.sv`, `mem/ventium_l1_axi_top.v` | L1D-to-64-bit AXI4 master subsystem (burst line fills, write-back/eviction, byte-exact narrow UC reads/writes, `route_err` guard) plus Verilog-2001 Vivado BD wrapper (`ventium_l1_axi_top.v`). |
| `mem/ven_axi_cdc.sv`, `mem/ven_cdc_afifo.sv`, `mem/ven_reset_sync.sv` | Asynchronous FIFO AXI4 clock-domain crossing and reset synchronizer primitives. |
| `northbridge/ven_cachemap.sv` | 430FX-style PAM/TOM physical memory-type and cacheability classifier (`KEN#` equivalent, VGA/ROM/PCI-hole/SMRAM region decode). |
| `mem/dcache_timing.sv` | Legacy tag-only L1D cycle-penalty model used **only** in standalone non-`VEN_L1_AXI` unit testbenches (compiled out on FPGA / `VEN_L1_AXI`). |

### 4. x87 Floating-Point Hierarchy (`../fp_shared/` & `rtl/fpu/`)

- **Production Shared x87 FPU (`../fp_shared/`, `+define+VEN_FP_SHARED`):** `ven_fp_top.sv` + `ven_fp_fxch_queue.sv` (zero-cycle `FXCH` rename/ordered admission slot) + `ven_fp_state.sv` (pointer-mapped 8×80-bit stack) + `ven_fp_alu.sv` (pipelined add/sub/mul) + `ven_fp_misc.sv` (compares, conversions, stores, environment) + `ven_fp_trans.sv` / `ven_fp_widemul.sv` / `ven_fp_estdiv.sv` (table-driven polynomial transcendentals). Consumes `72,204` LUTs and `38` DSP48E2 slices in `c0e3fe43` (down from `155k+` LUTs / `1,405` DSPs in split leaf engines). See [`../fp_shared/README.md`](../fp_shared/README.md).
- **Shared Leaf Services & Legacy Reference (`rtl/fpu/`):** `fpu_srt_div.sv` (unified radix-4 SRT `FDIV`/`FSQRT`/`FPREM`/`FPREM1` engine used by `ven_fp_top`), `ven_bcd.sv` & `ven_bcd_to_fp.sv` (iterative `FBSTP`/`FBLD` engines used by `ven_fp_top`), `fpu_*_rom.svh` constant tables, and the legacy non-shared modules (`fpu_top.sv`, `fpu_fx_ppl.sv`, `fpu_estdiv.sv`, `fpu_f2xm1.sv`, `fpu_fpatan.sv`, `fpu_fprem.sv`, `fpu_fyl2x.sv`, `fpu_fsincos.sv`, `fpu_sqrt_iter.sv`).

### 5. External Bus & Full-PC Platform Integration (`rtl/bus/`, `ao486-sim/`, `fpga/`)

- **Pin-Level P5 BIU (`bus/biu_p5.sv`, `bus/biu.sv`):** Standalone SVA-verified 64-bit Pentium external bus state machine (`ADS#`, `BRDY#`, `NA#`, `KEN#`, `CACHE#`, `LOCK#`, `AHOLD`/`EADS#`/`HITM#`, `BOFF#`, `HOLD`/`HLDA`) and optional `bus_mode=1` protocol exerciser (`make bus bus-sva`).
- **Full-PC Simulation & RK-XCZU15EG-F SoC:** In both `ao486-sim/` and `fpga/`, `ventium_top` + `ventium_l1_axi` connect via `ao486-sim/ven/ven_ao486_shim.sv` and `ven_axi2avalon.sv` into the MiSTer PC/AT chipset (`rtl_ven_soc.f`, outer L2 disabled/bypassed) and `fpga/rtl/ven_ddram_axi_posted.sv` (16-slot posted DDR4 write queue with CAM read-after-write bypass and architectural external-drain barrier into ZynqMP `S_AXI_HP0_FPD`).
