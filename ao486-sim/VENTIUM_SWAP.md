# Ventium ↔ MiSTer `ao486` SoC Core Swap (`ven_ao486_shim`)

This document specifies the CPU-to-platform integration seam shared by both the
full-PC Verilator harness (`ao486-sim/ven/`) and the **RK-XCZU15EG-F** physical
FPGA SoC (`fpga/rk/`).

> **Physical Qualification Status (`c0e3fe43`, 2026-11-14):** Using this exact
> `ven_ao486_shim` + `ven_axi2avalon` seam (`rtl_ven_core.f` + `rtl_ven_soc.f`),
> board-qualified `main` release image **`c0e3fe43`** (`161` defines,
> `40.264133 MHz` STA-signed-off on `xczu15eg-ffvb1156-2-i`, `cycle_mode = 1'b1`)
> passes all three physical standard-suite gates: both CoreMark seeds
> (`2.100128 / 2.106796 CM/MHz`), cold Windows 95 OSR2 GUI multi-application
> desktop + PS/2 mouse/keyboard + clean shutdown, and cold DOS Quake `demo1`
> (`8.0 FPS` at `40.000 MHz`). Verified physical interior Quake gameplay IPC is
> **`0.515778001` total U+V** (`0.397847833` primary/U-only, counters include
> `REP`-element retirement) across cycles **`28,696,827,616–32,989,404,795`**.
> Ongoing RTL work on `experimental/uv-fast-ipc-apr` requires fresh QEMU
> differentials and full-suite re-qualification.

---

## 1. Architecture — Drop-In Core Swap at `system.v`

In `3rd-party/ao486_MiSTer/rtl/system.v`, `+define+VEN_CORE` replaces the single
`ao486` CPU instance with **`ven_ao486_shim`** (`ao486-sim/ven/ven_ao486_shim.sv`),
leaving all legacy PC/AT peripherals (`iobus`, dual `8259A` PIC, `8254` PIT,
`8237` DMA, `MC146818` RTC, `8042` PS/2, dual IDE, floppy, planar/256-color VGA,
and Sound Blaster 16 / OPL3) intact:

```text
             ┌───────────────────── ven_ao486_shim.sv ──────────────────────┐
  system.v ──┤  ventium_top (U+V fast-pipe, shared 80b x87, 8 KiB I$ + D$)  ├── system.v
  PC/AT SoC  │    ├─ m_axi_* ──► [REMAP undo + A20] ──► ven_axi2avalon ──►  │  avm_* (VGA / ROM / DDR)
             │    ├─ io_*    ──► [split I/O + done-race guard] ──────────►  │  io_read_* / io_write_*
             │    ├─ intr / inta_vector / inta ◄─────────────────────────►  │  8259A PIC handshake
             │    └─ dbg_bus[290:0] / dbg_cmp[127:0] ◄───────────────────►  │  PMU / trace / DDR drain
             └──────────────────────────────────────────────────────────────┘
```

---

## 2. Seam Port Contract (`ven_ao486_shim`)

| Signal Group | `system.v` Port(s) | Dir | Seam Behavior |
| --- | --- | --- | --- |
| Clock / Reset | `clk`, `rst_n` | in | Synchronous core/SoC clock (`40.000 MHz` boot on FPGA) & active-low reset |
| A20 Gate | `a20_enable` | in | Masks physical address bit 20 (`~32'h0010_0000`) when deasserted |
| Legacy Cache Pin | `cache_disable` | in | Ignored at pin boundary; Ventium honors architectural `CR0.CD` via `VEN_L1_HONOR_CD` |
| 8259A Interrupts | `interrupt_do`, `interrupt_vector[7:0]`, `interrupt_done` | in/out | Maps 1:1 to `ventium_top` `intr`, `inta_vector`, and single-cycle `inta` pulse |
| Avalon-MM Memory | `avm_address[29:0]`, `avm_writedata[31:0]`, `avm_byteenable[3:0]`, `avm_burstcount[3:0]`, `avm_write`, `avm_read`, `avm_waitrequest`, `avm_readdatavalid`, `avm_readdata[31:0]` | master | Driven by `ven_axi2avalon`; routes legacy VGA (`0xA0000–0xBFFFF`), ROM shadow (`0xC0000–0xFFFFF`), and system DDR |
| ISA Slave DMA | `dma_*` | slave | Tied idle (`dma_waitrequest = 0`); IDE uses PIO/mgmt sectors |
| Split Port I/O | `io_read_do/address/length/data/done`, `io_write_do/address/length/data/done` | master | Adapts `ventium_top` unified `io_*` (`1`/`2`/`4`-byte exact `IN`/`OUT`) |
| Debug & Drain | `dbg_bus[290:0]`, `dbg_cmp[127:0]` | out/in | Exposes `UV64` total U+V retirement counters (selectors `76..79`), scan/trace rings, and `VEN_DDR_POSTED` hardware drain status (`dbg_cmp[109:107]`) |

---

## 3. Synthesized Core & Cache Configuration (`rtl_ven_core.f` / `rtl_ven_soc.f`)

- **Dual-Issue Superscalar Pipeline:** Hardwired `cycle_mode = 1'b1` (`U/V +
  system fast-pipe`: `VEN_FE_PIPE`, `VEN_SYS_FASTPATH`, `VEN_SYS_FASTPATH_RELOC`,
  `VEN_SYS_FASTLOAD_FLAT`, `VEN_SYS_FASTLOAD_BOUNDED`, `VEN_SYS_FASTSTORE_FLAT`,
  `VEN_REP_STOS_STREAM`), 32-entry 4-way I-TLB, 64-entry 4-way D-TLB, and
  dual-ported 256-entry 4-way BTB + 4-entry RAS.
- **Full P5 Split L1 Caches:** 8 KiB 2-way snoop-coherent L1 I-Cache (`8×RAMB36`
  data + LUTRAM tags) and 8 KiB 2-way 8-bank dual-port-read L1 D-Cache
  (`ven_l1d` + `ven_p54_hit_return`, write-back/write-allocate, honoring `CR0.CD`
  and byte-exact UC MMIO) driving `ven_axi_master` (`VEN_L1_AXI`, `l1axi_en = 1`).
  `VEN_CACHE_HALF` and `VEN_IC_NARROWB` are retired and forbidden.
- **Shared Pipelined 80-Bit x87 FPU (`fp_shared/`):** Zero-cycle `FXCH` rename
  queue, pipelined `ven_fp_alu`, 38-DSP shared multiplier & polynomial
  transcendental engine (`VEN_TRANSCENDENTAL`, `VEN_FPREM`), and radix-4 SRT
  divider/sqrt (`VEN_FP_SHARED`, `VEN_FP_PIPE2`).
- **Cold Boot Vector:** `boot_mode = 1'b1`, `soc_en = 1'b1`, `cosim_en = 1'b1`,
  starting cleanly in real mode at `CS:EIP = F000:FFF0`.

---

## 4. Protocol Adapters Inside `ven_ao486_shim`

### 4.1 AXI4-to-Avalon-MM Bridge (`ao486-sim/ven/ven_axi2avalon.sv`)

1. **Address Normalization & A20:** `ven_ao486_shim` removes `REMAP_BASE`
   (`40'h0_4000_0000`) from `ventium_top`'s AXI4 physical address, applies
   `a20_enable` to bit 20, and passes byte addresses into `ven_axi2avalon`,
   which drives dword-indexed `avm_address[29:0] = addr[31:2]`.
2. **Burst & Byte-Lane Fidelity:** Cache-line fills (`ARLEN = 7`, 32 B) map to
   `avm_read` bursts (`avm_burstcount = 8`), returning 8 `avm_readdatavalid`
   beats on AXI `R` (`RLAST` on the final beat); narrow UC reads and single-beat
   writes preserve exact `ARSIZE` / `WSTRB` (`avm_byteenable[3:0]`) without
   widening non-cacheable accesses. Directed testbench:
   `ao486-sim/ven/tb_axi2avalon.sv`.

### 4.2 Split Port-I/O & Posted-DDR Drain Barrier

- Converts `ventium_top` `io_req`/`io_we` into `io_read_do` / `io_write_do` and
  deasserts the request strobe immediately upon `io_read_done | io_write_done`
  (`io_done_seen` guard) so multi-cycle core retirement cannot re-trigger a
  second peripheral read/write side effect.
- When `VEN_DDR_POSTED` is enabled on FPGA (`ven_ddram_axi_posted.sv`), posted
  write acceptance is **not** external completion: `dbg_cmp[108:107]` gates I/O,
  debug halt, and MMCM DRP clock switches until all 16 posted DDR4 write slots
  drain to `S_AXI_HP0_FPD` with zero sticky fault (`dbg_cmp[109] == 0`).

---

## 5. Memory Hierarchy & Self-Modifying Code Coherency

- **Hardware FPGA Path (`c0e3fe43`):** `ventium_top` → `ven_l1d` + snooped
  `u_icache` → `ven_axi_master` → `ven_ao486_shim` → `ven_axi2avalon` →
  bypassed outer `ao486` `l2_cache` wrapper (retaining legacy VGA/ROM decode) →
  `ven_ddram_axi_posted` (16-slot posted write queue + CAM read-after-write
  hazard bypass) → `128b @ 100 MHz` `S_AXI_HP0_FPD` DDR4 (`0x6000_0000`).
- **Self-Modifying / Relocated Code:** Store commits snoop L1 I-Cache tags and
  prefetch buffers across real-mode relocation (e.g. `IO.SYS` `REP MOVSB` to
  `0x8000:0000`) and protected-mode DPMI/VxD code loading.

---

## 6. Clean PL / PS Responsibility Split

- **Synthesized RTL (`system.v` + `ven_ao486_shim`):** Full P5/P54C CPU, x87
  FPU, split L1 caches/TLBs, and all cycle-visible PC/AT ISA peripherals (`PIC`,
  `PIT`, `RTC`, `8042` PS/2, `IDE` taskfile, `VGA`, `DMA`, `SB16`/`OPL3`).
- **Host / ARM PS Layer:** Serves backing media (`mgmt_*` IDE/FDD sector streams,
  BIOS/VGA ROM initialization, CMOS seed), passive framebuffer capture, hosted
  PS/2 keyboard/mouse mailboxes, and DDR4 memory backing — never intercepting
  x86 `IN`/`OUT` instructions in software.

---

## 7. Verilator Co-Sim Harness (`ao486-sim/ven/sim_ven.cpp`)

`make -C ao486-sim ven` links the exact `rtl_ven_core.f` + `rtl_ven_soc.f` RTL
lists with:

- `ao486-sim/ven/sim_ven.cpp`: Cycle loop, configurable DDR latency/board-AXI
  transport model (`board_axi_memory.h`), performance/pairing samplers,
  deterministic `--snapshot-v3`/`--snapshot-v4` save/restore, and `.vtm`/delta
  diagnostics.
- `ao486-sim/ven/vtm_dpi.cpp`: Read-only `vtm_retire*` DPI retirement observers
  (see [`../docs/rtl-interface.md`](../docs/rtl-interface.md)).
- `ao486-sim/ps/{ps_shim.cpp,ide.cpp,support/x86/x86.cpp}`: Shared MiSTer PS
  backing services with immediate `fflush` host-write visibility
  ([`ven/DISK_WRITE_VISIBILITY.md`](ven/DISK_WRITE_VISIBILITY.md)).

For build flags, private `VEN_OBJDIR` rules, cold-boot commands, and checkpoint
replay verification, see [`REPRODUCE.md`](REPRODUCE.md).
