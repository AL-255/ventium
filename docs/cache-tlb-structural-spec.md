# P54C Cache & TLB Structural Architecture Spec

> **Current Status (Nov 2026 — IMPLEMENTED in `VEN_L1_AXI` / `c0e3fe43`):** Both the set-associative P54C TLBs (`rtl/mem/tlb_assoc.sv`) and the real data-holding 8 KiB 2-way 8-bank L1 D-Cache (`rtl/mem/ven_l1d.sv` + `ven_p54_bank_arb.sv` + `ven_p54_hit_return.sv`) are implemented and board-qualified in RK-XCZU15EG-F image **`c0e3fe43`** (`40.264133 MHz` STA sign-off, `0.515778001` total U+V / `0.397847833` primary/U Quake gameplay IPC across cycles `28,696,827,616–32,989,404,795`). The earlier 16-entry direct-mapped `tlb.sv` and tag-only `dcache_timing.sv` remain only for legacy standalone unit-TB configurations.

---

## 1. Documented Pentium (P5/P54C) Reference Organization

Primary Intel sources (`Pentium Processor Family Developer's Manual Vol. 1`, 241428-004 §2.5 & Ch. 3; Alpert & Avnon, *IEEE Micro* 1993, p. 15; AP-500, 241799 p. 3):

- **Split L1 Caches (non-MMX P54C):** Separate **8 KiB code + 8 KiB data** caches (`128` sets × `2` ways × `32` B lines), LRU replacement.
  - **L1 D-Cache Banking:** 8 banks interleaved on 32-bit word boundaries (`addr[4:2]`), allowing simultaneous U-pipe and V-pipe accesses to distinct banks (`+1` clock V-pipe stall on bank conflict). Write-back with write-allocate by default (`PWT`/`PCD` and region cacheability honored).
- **Split Set-Associative TLBs:**
  - **I-TLB:** **32-entry, 4-way set-associative** (`8` sets × `4` ways) with 3-bit pseudo-LRU replacement (4 MiB pages cached as 4 KiB translations).
  - **D-TLB:** **64-entry, 4-way set-associative** (`16` sets × `4` ways) with pseudo-LRU replacement (plus 4 MiB PSE support).

---

## 2. Implemented Ventium Hardware (`rtl/mem/`)

### 2.1 Set-Associative I-TLB & D-TLB (`tlb_assoc.sv`)

- **Deployed Configuration (`c0e3fe43`):**
  - **D-TLB (`VEN_DTLB_ASSOC_4WAY`):** 64-entry, 4-way set-associative (`16` sets × `4` ways), pseudo-LRU victim selection, supporting both 4 KiB pages and 4 MiB PSE large pages, dirty-bit write re-walk, and `CR3` / `INVLPG` invalidation.
  - **I-TLB (`VEN_ITLB_ASSOC_4WAY`):** 32-entry, 4-way set-associative (`8` sets × `4` ways), pseudo-LRU replacement, eliminating direct-mapped code-page thrashing across Windows 95 and Quake working sets.
  - **Registered Front-End Page Filters (`VEN_FE_PIPE`):** `fe_itlb_q` and `fe_dtlb_q` cache the active 4 KiB translation in registers so intra-page `S_PIPE` fetches and loads avoid combinational associative tag-compare cones on the 40 MHz critical path (`8,223` LUTs / `4,780` FFs combined across all TLB structures in `c0e3fe43`).
- **2-Level Hardware Page Walker:** Resides in `rtl/core/core_walk.svh` (`S_WALK`), performing atomic `PDE`/`PTE` reads, `Accessed`/`Dirty` bit updates, and `#PF` (`CR2` + error code) generation while freezing split-page fragment shaping (`fx_walk_hold`).
- **Legacy Unit-TB Baseline (`tlb.sv`):** Retains the 16-entry direct-mapped array when associative TLB defines are disabled in basic unit tests.

### 2.2 Split 8 KiB L1 I-Cache (`icache.sv`) & 8 KiB L1 D-Cache (`ven_l1d.sv`)

- **L1 I-Cache (`icache.sv`):** 8 KiB, 2-way, 32 B lines (`8` RAMB36 tiles + LUTRAM tags under `VEN_IC_BRAM`). Stores physical page tags (`ic_ptag`) on every line so CPU stores and DMA writes snoop-invalidate all linear aliases (`run-ic-alias-gate.sh`), honors `CR0.CD` and `ven_cachemap` cacheability, and replicates `pf_fill_addr_rep[0..3]` for congestion-free routing.
- **L1 D-Cache (`ven_l1d.sv` + `ven_p54_bank_arb.sv` + `ven_p54_hit_return.sv`):**
  - **Geometry & Banking:** 8 KiB, 2-way, 32 B lines (`128` sets), with 8-way 32-bit word-interleaved bank arbitration (`ven_p54_bank_arb`) and dual-port U+V read hit return (`ven_p54_hit_return`) enforcing the AP-500 `addr[4:2]` bank-conflict rule (`ven_p54_bram_bank.sv` / `ven_p54_bram_data.sv` provide dedicated BRAM bank wrappers).
  - **Write Policy & Coherence:** Supports write-back / write-allocate dirty-line eviction as well as write-through/uncacheable bypass, `CR0.CD` + `ven_cachemap` (`KEN#` equivalent) region attributes, per-byte cached-store policy (`VEN_L1D_STORE_POLICY` for `0xC0000–0xFFFFF` ROM/UMA windows), and physical snoop invalidation.
  - **Backing Fabric (`ventium_l1_axi.sv` + `ven_axi_master.sv`):** Bridges cache line fills, dirty evictions, and byte-exact fragmented non-cacheable MMIO reads/writes (`ARSIZE`-exact, never crossing 4 KiB) onto a 64-bit AXI4 master (`8,412` LUTs / `2,105` FFs in `c0e3fe43`). Outer MiSTer L2 is disabled/bypassed on FPGA; DDR4 traffic flows through `ven_ddram_axi_posted` (16-slot posted write queue with CAM RAW hazard bypass and architectural external-drain barrier).
- **Legacy Unit-TB Model (`dcache_timing.sv`):** Tag/LRU-only cycle-penalty estimator compiled **only** when `VEN_L1_AXI` is off in standalone core unit tests.

---

## 3. Remaining Out-of-Scope Multi-Socket Bus Items

Ventium models a **uniprocessor PC/AT SoC** (`ao486-sim` and `RK-XCZU15EG-F`):
- Local DMA/self-modifying-code coherence is enforced via physical snoop invalidations and posted-DDR drain barriers rather than multi-CPU socket-to-socket `EADS#`/`HITM#` cache-to-cache interventions on external package pins (`rtl/bus/biu_p5.sv` verifies the pin-level P5 inquire/HITM# protocol standalone under `make bus`).
- Separate 8-entry dedicated 4 MiB D-TLB array: 4 MiB PSE translations are served directly by `tlb_assoc.sv` rather than a physically separate 8-entry CAM.
