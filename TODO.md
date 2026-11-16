# Ventium — Project Status & Open Experimental Work

_Last updated: 2026-11-15_

## 1. Current Verified Physical Baseline (`c0e3fe43` on `main`)

The published **`main`** branch (`v0.2.0-c0e3fe43`, commit `64e567a6`) holds the self-contained, hash-pinned hardware source closure (`fpga/known_good_c0e3fe43.json`, `193` files, `161` defines in `fpga/known_good_defines.txt`) for board-qualified image **`c0e3fe43`** on **RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`, AMD Vivado **2025.2**):

- **Verified Physical Quake Gameplay IPC:** **`0.515778001` total U+V IPC** (**`0.397847833` primary/U-only IPC**) across interior gameplay cycles **`28,696,827,616–32,989,404,795`** (`2,214,014,744` U+V events, `506,223,958` paired V retirements; hardware counters include `REP`-element retirement). Prior release baseline `2886d24c` (2026-10-17): `0.496499864` total U+V / `0.383002768` primary/U across cycles `625,021,130,428–629,480,208,865` (`+3.88%`).
- **Physical Standard Acceptance Suite (`40.000 MHz`, `U/V + system fast-pipe`, `cycle_mode=1`):**
  1. **CoreMark:** Both standard 4,000-iteration seeds pass with all 5 reference CRCs matched (`2.100128 / 2.106796 CM/MHz`).
  2. **Windows 95 OSR2 GUI:** Cold boot to clean desktop, interactive PS/2 mouse & keyboard session across Calculator (`355/113`), Notepad, and MS Paint, plus clean OS shutdown.
  3. **DOS Quake `timedemo demo1` + Gameplay:** **`8.0 FPS`** (`969` frames in `121.2 s` at measured `39.999802 MHz`, zero errors) plus interactive single-player gameplay.
- **Post-Route Static Timing & Congestion Sign-Off:** Closed at **`40.264133 MHz`** (`WNS = +0.164 ns`, `WHS = +0.010 ns`, `0` failing endpoints, `0` DRC/routing errors, `0` `>=85%` global routing hotspots; `171,819` LUTs / `50.35%`, `30,703` CLBs / `71.97%`, `39,520` FFs / `5.79%`, `277.5` BRAM36-eq / `37.30%`, `47` DSP48E2 / `1.33%`).
- **Empirical Single-Board Runtime MMCM DRP Overclocking (Not STA Sign-Off Above 40 MHz):** `58.824 MHz` (`N = 17`, cold Win95 GUI + Quake pass) and `62.500 MHz` (`N = 16`, cold DOS Quake `demo1` `11.6 FPS` + interactive `E1M1` pass; `66.667 MHz` `N = 15` exceeds setup margin).

> **Experimental Branch Boundary (`experimental/uv-fast-ipc-apr`):** Working RTL and post-freeze commits on `experimental/uv-fast-ipc-apr` (`HEAD` `5c630403` + local harness/RTL edits) are **unmeasured** on physical gameplay and do **not** inherit `c0e3fe43` qualification until separately verified through the differential gates and full physical standard suite.

---

## 2. Completed Major Milestones

- [x] **M0–M4 — Dual-Issue P5/P54C Core & QEMU Lockstep Harness:** Full non-MMX P5 integer ISA, protected/V86/paged/SMM system modes, AP-500 U+V pairing, dual AGUs, 256-entry 4-way dual-ported BTB + 4-entry RAS, and Verilator/QEMU `.vtrace` lockstep verification.
- [x] **M5–M11 — Split 8 KiB L1 Caches, 4-Way TLBs & Shared Pipelined x87 FPU:** 8 KiB L1 I-Cache, 8-bank dual-port-read 8 KiB L1 D-Cache (`ven_l1d` + `ven_p54_hit_return` + `ven_axi_master`), 32-entry 4-way I-TLB (`VEN_ITLB_ASSOC_4WAY`) + 64-entry 4-way D-TLB, hardware radix-2 `ven_idiv`, and `fp_shared/` 80-bit x87 FPU with zero-cycle `FXCH` rename queue, 38-DSP polynomial transcendentals, and radix-4 SRT div/sqrt.
- [x] **Tier-1 IPC & 40 MHz STA Closure (`c0e3fe43`, 2026-11-14):** 4-way I-TLB, dual-ported 256-entry BTB, pipelined `REP STOS` cacheable store streaming (`VEN_REP_STOS_STREAM`), fast-path `MOVZX`/`MOVSX` loads, 16-slot posted-DDR4 CAM read-after-write bypass, `pf_fill_addr_rep[0..3]` fanout replication, and `retime_muxf_route_first` closure at `40.264133 MHz`.
- [x] **Public Hardware Release & Physical Floorplan Documentation:** Self-contained 193-file `main` build (`fpga/build_known_good.py`), vector SoC architecture diagram (`docs/ventium-architecture.svg`), and exact per-CLB component/congestion floorplans (`docs/FPGA_PHYSICAL_MAP_2026-11-14.md`).

---

## 3. Active & Open Experimental Tracks (`experimental/uv-fast-ipc-apr`)

### 3.1 Branch Reconciliation & Differential Gate Unification
- [ ] **Port `main` (`c0e3fe43`) RTL closure back into `experimental/uv-fast-ipc-apr`:** Reconcile `c0e3fe43`'s 161-define hardware fixes (including the 9 x87 correctness fixes, 7 `ven_l1d` LUTRAM/hit-under-ifill upgrades, 4-way I-TLB, dual-ported BTB, `REP STOS` streaming, `MOVZX`/`MOVSX` fast loads, posted-DDR CAM bypass, and `pf_fill_addr_rep` fanout relief) with `experimental/uv-fast-ipc-apr`'s verification harness without losing local `Makefile` / `verif/` / `ao486-sim/` improvements.
- [ ] **First-class 161-define FPGA-profile differential target:** Add an isolated `VTM_VERIFY_BIN_DIR` Verilator regression mode (`--cycle-func --l1-axi`) exercising the exact `fpga/known_good_defines.txt` hardware profile against the pinned QEMU Pentium oracle.

### 3.2 APR Timing Closure & Area Optimization on Experimental RTL
- [ ] **Bridge the experimental-vs-release STA gap (`35.736 MHz` vs. `40.264 MHz`):** On the heavier post-freeze `experimental/uv-fast-ipc-apr` RTL tree (`HEAD` `5c630403`), isolated fresh-source APR exploration concluded at the accepted legal **`35.736 MHz`** MUXF route (`a8e5d6bf` / `5c630403`). Re-apply `c0e3fe43`'s front-end fanout/mux reductions and audit LUT/MUXF growth before re-qualifying any post-freeze core, `uopcache`, or FPU candidates at `40 MHz`.
- [ ] **Consolidate `u_fp_shared` LUT footprint (`72,204` LUTs in `c0e3fe43`):** Share wide barrel shifters and normalization/rounding cones in `ven_fp_trans.sv` and stream `FNSAVE`/`FRSTOR` state transfers instead of wide combinational crossbars.
- [ ] **Pipeline separation toward `>50 MHz` STA:** Continue breaking long `S_PIPE` fetch-to-DTLB-to-L1D combinational cones across true registered `PF / D1 / D2 / EX / WB` boundaries using BRAM-backed data/BTB arrays (`ven_p54_bram_data.sv` experiments).

### 3.3 Next-Wave P54C IPC & Microarchitectural Fidelity Candidates
- [ ] **Precision-gated early termination in `fpu_srt_div.sv`:** Terminate radix-4 SRT `FDIV` by `FCW.PC` (`~19` clocks for single-precision `PC=00` and `~33` clocks for double-precision `PC=10`, down from `38–39` clocks) to match P54C latency on Quake perspective divides.
- [ ] **VIPT physical-tag lookup in `icache.sv` & selective TLB invalidation:** Lookup `ic_ptag` directly so `MOV CR3` context switches preserve the 8 KiB I-Cache, and prevent `CLTS`, non-paging `MOV CR0` (`TS` toggles), and single-page `INVLPG` from triggering global TLB/I-Cache flushes.
- [ ] **Inner `ven_axi_master` read-around-write & dedicated I-Cache refill:** Allow cacheable read misses in `ven_axi_master.sv` to bypass non-conflicting buffered writes (matching `ven_ddram_axi_posted.sv`'s outer CAM bypass) and burst-commit 256-bit code lines into `icache.sv` without stepping `S_PF` words serially.
- [ ] **Expanded AP-500 U/V pairing & `S_PIPE` coverage:** Evaluate admitting `Reg-ALU/MOV (U) + Store (V)`, `PUSH imm8/imm32`, `MOV [base], imm32`, register `FCOM`/`FNSTSW AX`, and V-pipe `FXCH` pairing without regressing `40 MHz` setup slack, plus MESI write-back L1D evaluation.

### 3.4 Platform SoC, Simulation Harness & Deferred ISA Edge Cases
- [ ] **8237 ISA DMA bridge in `ven_ao486_shim.sv`:** Route `dma_*` read/write cycles to memory with physical L1I/L1D invalidation snoops so Sound Blaster 16 audio DMA and Floppy DMA work in DOS Quake (currently run with `-nosound`) and Windows 95.
- [ ] **ISA & privilege corner-case tightening (see [`docs/isa-coverage.md`](docs/isa-coverage.md) & [`docs/modeled-by-effect.md`](docs/modeled-by-effect.md)):**
  - Gate `INVD`/`WBINVD` cache-flush side effects strictly on `CPL == 0 && !VM` prior to `#GP(0)`.
  - Unify A20 masking and `ven_l1d` physical-alias invalidation across `core_io.svh` and `ven_ao486_shim.sv`; extend PS DMA flushes across the outer platform cache.
  - Align `CPUID` leaf 1 feature bits (`EDX`/`ECX`) strictly with non-MMX P54C hardware (clear `MMX`/`Hypervisor`; gate `MSR`/`MCE` on P54C MSR `0x00..0x13` implementation).
  - Enforce `SS.B` stack-pointer width on `0x66 ENTER` in 32-bit segments, conforming-code `DS/ES/FS/GS` loads, `PTE.PCD`/`PWT` cacheability propagation, IDT/call task gates, and legacy `CR0.NE=0` (`FERR#`/`IGNNE#`/IRQ13) + unmasked x87 exception corner cases.
- [ ] **Verilator full-PC harness (`ao486-sim/`) maintenance:** Keep `ao486-sim/` define profiles synchronized with `fpga/known_good_defines.txt` and evaluate decoupling the C++ HPS management service onto an asynchronous scheduler.
