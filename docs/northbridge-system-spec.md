# Physical Memory Map, Coherence & Platform Integration Spec

> **Current Status (Nov 2026 — Superseded on SoC/FPGA by MiSTer PC/AT + `ven_ddram_axi_posted`):**
> - **Implemented & Active in `rtl/`:** `rtl/northbridge/ven_cachemap.sv` (430FX-style PAM/TOM physical region & cacheability classifier), `CR0.CD` + `KEN#`-equivalent uncacheable bypass, physical snoop-invalidation on both `ven_l1d.sv` and `icache.sv`, byte-exact narrow UC AXI transactions (`ven_axi_master.sv`), `route_err` non-DRAM protection (`ventium_l1_axi.sv`), and `VEN_L1D_STORE_POLICY` (`0xC0000–0xFFFFF` ROM/UMA protection).
> - **Production PC Platform (`ao486-sim/` & `fpga/`, image `c0e3fe43`):** Instead of building custom `ven_northbridge` / `ven_southbridge` / `ven_l2` wrappers around the early `rtl/soc/*` models (now retired), Ventium integrates directly into the full **MiSTer PC/AT chipset** (`rtl_ven_soc.f`: dual `8259A` PIC, `8254` PIT, `8237` DMA, `MC146818` RTC, PS/2 keyboard & mouse, dual IDE, floppy, VGA, Sound Blaster 16 + OPL3) via `ao486-sim/ven/ven_ao486_shim.sv` + `ven_axi2avalon.sv`. Outer L2 is **disabled/bypassed** (`EN_L2 = 0`); DDR4 traffic on RK-XCZU15EG-F (`c0e3fe43`, `40.264133 MHz` STA sign-off, `0.515778001` total U+V Quake gameplay IPC) traverses `fpga/rtl/ven_ddram_axi_posted.sv` (16-slot posted write queue + CAM read-after-write bypass + architectural external-drain barrier) into ZynqMP `S_AXI_HP0_FPD` (`0x6000_0000` `no-map` DDR4 carveout).

---

## 1. Physical Address Classification (`rtl/northbridge/ven_cachemap.sv`)

`ven_cachemap` decodes physical `addr[31:0]` combinationally into `{cacheable, region}` modeled on the Intel 430FX (82437FX TSC) PAM and Top-of-Memory (TOM) map:

| Physical Range | Region & Default Cacheability | Handling in `ventium_l1_axi` & `ven_ao486_shim` |
| --- | --- | --- |
| `0x0000_0000 .. 0x0009_FFFF` | Conventional DRAM — **Cacheable WB** | Cached in `icache` + `ven_l1d` (when `CR0.CD == 0`). |
| `0x000A_0000 .. 0x000B_FFFF` | Legacy VGA Aperture / SMRAM — **Uncacheable** | Never allocated in L1I/L1D; routed uncacheably to VGA plane RAMs (or DDR framebuffer in standalone TB). |
| `0x000C_0000 .. 0x000F_FFFF` | Option ROM & BIOS Shadow (`PAM0`–`PAM6`) | Per-segment R/W + cacheability; under `VEN_L1D_STORE_POLICY`, `ven_ao486_shim` suppresses cached byte updates and invalidates resident L1D tags on writes so ROM-discard / UMA policy in the platform backend stays authoritative. |
| `0x0010_0000 .. TOM - 1` | Extended System DRAM — **Cacheable WB** | Cached in `icache` + `ven_l1d` (minus optional 15–16 MiB ISA memory hole). |
| `TOM .. 0xFFFD_FFFF` | PCI / Unmapped Memory Hole — **Uncacheable** | Outside the declared `ADDR_MASK` RAM window, `ventium_l1_axi` suppresses DDR aliasing and asserts sticky `route_err` → `bus_err`. |
| `0xFFFE_0000 .. 0xFFFF_FFFF` | Top-of-4G BIOS Reset Vector Shadow | Mapped to high BIOS ROM / shadow RAM per platform fold. |

---

## 2. Coherence, Ordering & External Drain Invariants

1. **Physical Snoop-Invalidate (`icache.sv` & `ven_l1d.sv`):**
   - `icache.sv` records the physical page tag (`ic_ptag`) on every line fill. CPU stores and platform DMA writes snoop by **physical** address, invalidating all matching L1I and `uopcache` ways regardless of virtual/linear aliasing (`verif/l1/run-ic-alias-gate.sh`).
   - `ven_l1d.sv` exposes `snoop_inv_valid` / `snoop_inv_addr` for non-CPU DMA writes to DRAM alongside `flush_all` / `smm_flush` / `a20_flush`.
2. **Byte-Exact Uncacheable Accesses:**
   - Port I/O (`io_*`) uses a dedicated uncached channel into the PC/AT I/O bus.
   - Memory-mapped uncacheable accesses (`PCD=1`, `CR0.CD=1`, or `ven_cachemap` UC regions) bypass L1 allocation and fragment into aligned power-of-two single-beat AXI transfers with exact `ARSIZE`/`WSTRB`—never widening narrow MMIO reads or crossing a 4 KiB boundary (`verif/l1/run-l1axi-narrow-gate.sh`).
3. **Posted DDR4 Queue & True External Drain Barrier (`ven_ddram_axi_posted.sv`):**
   - On RK-XCZU15EG-F, `ven_ddram_axi_posted` absorbs up to 16 posted DDR4 writes with full CAM read-after-write hazard forwarding for subsequent CPU/DMA reads.
   - **Invariant:** Local posted write acceptance is *not* external DDR completion. Before committing I/O cycles with external side effects, entering debug halt, or executing runtime MMCM DRP clock switches (`ven_pll_ctrl`), hardware waits on the true external DDR drain/fault barrier so no queued write remains in flight.
4. **SMRAM Guard (`NB_SMRAM`):**
   - Pre-lookup core-seam (`core_smram_deny`) and backing-seam SMRAM isolation plus SMM-exit `smm_flush` are implemented and verified in `tb_l1axi_smram`, remaining default-off (`NB_SMRAM = 0`) because `0x30000` is conventional DOS RAM on standard PC/AT guests (see [`unsupported-isa.md`](unsupported-isa.md) §B.5).
