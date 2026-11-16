# Ventium "Modeled by Effect" vs Structural Hardware Inventory

Tracks which Pentium (P5/P54C) subsystems in Ventium are **structurally realized** in synthesizable hardware versus **modeled by architectural/cycle effect** (producing exact architectural results without replicating original P5 microcode ROM or transistor-level array structures).

> **Current Status (Nov 2026 — Image `c0e3fe43`):** Most high-impact items from the original June 2026 inventory (integer `DIV`/`IDIV` `#DE` + iterative `ven_idiv`, shared pipelined x87 + radix-4 SRT + BCD + polynomial transcendentals in `fp_shared/`, real 8 KiB 2-way 8-bank L1 D-Cache `ven_l1d`, and 4-way set-associative 64-entry D-TLB / 32-entry I-TLB `tlb_assoc`) have been **converted to real synthesizable hardware** and board-qualified on **RK-XCZU15EG-F** (`40.264133 MHz` STA sign-off, **`0.515778001` total U+V / `0.397847833` primary/U Quake gameplay IPC** across cycles `28,696,827,616–32,989,404,795`).

---

## 1. Subsystems Promoted to Structural Hardware (Closed Since Jun 2026)

| Subsystem | Current Hardware Realization (`c0e3fe43`) | Verification |
| --- | --- | --- |
| **Integer `DIV` / `IDIV` & `#DE`** | Synthesizable iterative radix-2 divider (`rtl/core/ven_idiv.sv`, `+VEN_IDIV_ITER`) + architectural `#DE` (vector 0) on divide-by-zero and quotient overflow (`core_exec.svh`; unit cycle-TB mode also models 17/25/41 `DIV` & 22/30/46 `IDIV` occupancy). | `t_div`, `mb_div*`/`mb_idiv32`, `verif/sys/tests/pde` |
| **x87 FPU, SRT & Transcendentals** | `fp_shared/` (`ven_fp_top`, `ven_fp_fxch_queue`, pipelined `ven_fp_alu`, unified radix-4 `fpu_srt_div`, iterative `ven_bcd`/`ven_bcd_to_fp`, table-driven `ven_fp_trans` + `ven_fp_widemul` + `ven_fp_estdiv`; `38` DSP48E2, full `RC`/`PC`/`C1` & 14/28/94/108 B env/save). | `make -C fp_shared test`, `make m3`, `make fpstore`, Quake `demo1`, Win95 Calculator |
| **8 KiB 8-Bank L1 D-Cache** | `rtl/mem/ven_l1d.sv` + `ven_p54_bank_arb.sv` + `ven_p54_hit_return.sv` (8 KiB, 2-way, 32 B lines, 8 word-interleaved banks for dual U+V reads, write-back/write-allocate + byte-exact UC bypass + physical snoop). `dcache_timing.sv` is retained only for non-`VEN_L1_AXI` unit tests. | `make l1`, CoreMark, Win95, Quake |
| **Set-Associative I-TLB & D-TLB** | `rtl/mem/tlb_assoc.sv` (**32-entry 4-way I-TLB** `VEN_ITLB_ASSOC_4WAY` + **64-entry 4-way D-TLB** `VEN_DTLB_ASSOC_4WAY`, pseudo-LRU) + registered `fe_itlb_q`/`fe_dtlb_q` front-end page filters (`VEN_FE_PIPE`). `tlb.sv` is unit-TB only. | `make l1`, `make verify-sys` |
| **`REP STOS` Fast Store Streaming** | `VEN_REP_STOS_STREAM` pipelines cacheable present writable `REP STOSB/W/D` stores at 1 element/clock with exact page, segment-limit, and interrupt boundaries. | `make verify-sys`, Win95, Quake |

---

## 2. Subsystems Intentionally Modeled by Effect / FSM Microsequencing

The items below produce **exact IA-32 architectural state** (verified against pinned QEMU and on physical Win95/Quake hardware), while using synthesizable SystemVerilog state machines or DSP multipliers rather than a literal P5 microcode PLA/ROM:

| # | Block | Current RTL Implementation | Remaining Difference vs Original P54C Silicon |
| --- | --- | --- | --- |
| 1 | **Integer `MUL` / `IMUL`** | Synthesizes onto FPGA `DSP48E2` slices (`9` DSPs in `core`) with exact `CF`/`OF` overflow flags and modeled 10-cycle U-pipe non-pairable occupancy (`pending_mem_pen`, `mb_mul`/`mb_imul2`). | Uses FPGA hard DSP multipliers + modeled occupancy counter rather than a discrete multi-cycle Booth adder array. |
| 2 | **Complex / Microcoded Instructions (`PUSHA`/`POPA`, `PUSHF`/`POPF`, `CALL`/`RET` far, non-`STOS` `REP` strings, `ENTER`/`LEAVE`)** | Sequenced directly as explicit FSM states and `S_USEQ` beat loops in `core_*.svh` (no microcode ROM/PLA). | Architecturally exact; per-instruction cycle counts on non-streamed complex ops reflect Ventium's FSM beats rather than P5 microcode ROM cycle counts. |
| 3 | **Hardware Task Switch (`S_TSW_*`), Interrupt Gates (`S_INT_*`) & SMM (`S_SMI_SAVE`/`S_RSM`)** | Explicit beat-sequenced state machines in `core_tsw.svh`, `core_int_deliver.svh` (`ven_frame_plan.sv`), and `core_smm.svh`. | Clean execution is differentially exact (`ptask*`, `pcpl`, `pxwrap`, `psmm`); mid-task-switch fault-injection partial state follows [`tsw-phase-model.md`](tsw-phase-model.md) (`ptswflt` witness gate). |
| 4 | **Hardware 2-Level Page-Table Walker (`S_WALK`)** | FSM in `core_walk.svh` reading `PDE`/`PTE`, atomically setting `A`/`D` bits, and raising `#PF` (`CR2` + error code) with `fx_walk_hold` split-page freeze. | Architecturally exact (`ppage`, `pfault`, `xc04`); walk cycle count reflects actual `ven_l1d` / AXI memory latency rather than P5 host-bus pin timing. |
| 5 | **External Memory Bus (`ventium_l1_axi` vs `biu_p5`)** | Production SoC/FPGA (`VEN_L1_AXI`) uses a 64-bit AXI4 master (`ven_axi_master` → `ven_ao486_shim` / `ven_ddram_axi_posted`). Pin-level 64-bit P5 `ADS#`/`BRDY#`/`HITM#` (`rtl/bus/biu_p5.sv`) is verified standalone (`make bus`) and as a parallel protocol exerciser in `bus_mode=1` (`make bus-sva`). | SoC/FPGA memory traffic uses AXI4 + posted DDR4 with drain barriers rather than external 66 MHz Socket 5/7 package pins. |
