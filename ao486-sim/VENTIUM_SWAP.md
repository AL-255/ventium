# Ventium ↔ ao486-SoC core swap — integration design

**Goal.** Replace the ao486 CPU core inside the *proven* ao486 MiSTer SoC with the
Ventium (P5/P54C replica) core, co-simulated in Verilator the same way as the ao486
sim (real C++ PS + real RTL peripherals, **no golden replay**), and drive it to
**Quake timedemo completion** and **Win95 desktop**, with a clean PS/RTL split.

**Why this is plausible.** The ao486 sim proves the SoC-minus-core is good (it boots
Win95). The Ventium core is independently proven (98/98 functional diff-clean vs
QEMU; system-mode seg/paging/IDT/TSS/SMM done; x87 + transcendentals; it self-drove
SeaBIOS POST + FreeDOS to `C:\>` in its *own* SoC). What Ventium has never had is a
real ISA-peripheral environment — which is exactly what this SoC provides.

---

## 1. Strategy — keep the SoC + PS, swap only the core box

The ao486 core is instantiated at `system.v:296` (`3rd-party/ao486_MiSTer`). Its port
list (`ao486.v:29-76`) is the **entire** CPU seam. We introduce a drop-in module
**`ven_ao486_shim`** that presents that *exact* port list and internally wraps
`ventium_top` + protocol adapters. `system.v` is patched at one instantiation site
(`ao486 ao486(...)` → `ven_ao486_shim u_cpu(...)`); *all* peripheral wiring (iobus,
pic, dma, l2, mgmt, vga, ide, pit, rtc, ps2) is untouched. The MiSTer HPS C software
(the ao486-sim PS: BIOS/ROM load, CMOS, IDE/mgmt disk serving, framebuffer, PS2,
clock/DDR service) is **peripheral-agnostic** and reused verbatim — the golden-replay
harness is dropped.

```
             ┌──────────────── ven_ao486_shim (presents ao486 port list) ─────────────────┐
  system.v ──┤  ventium_top (VEN_L1_AXI + VEN_KV260_SOC + cosim_en)                        ├── system.v
  peripherals│    ├ m_axi_*  ─► [AXI4→Avalon bridge]  ─► avm_*  (→ l2_cache → DDRAM → PS)   │  peripherals
  (KEPT)     │    ├ io_*      ─► [io split adapter]    ─► io_read_*/io_write_* (→ iobus)     │  (KEPT)
             │    ├ intr/inta ◄─►[interrupt adapter]   ◄─► interrupt_do/vector/done (→ pic)  │
             │    └ (addr)    ─► [A20 gate]            ─► a20_enable applied                 │
             │  dma_* slave port: tied off (no ISA DMA on the IDE-PIO boot path)            │
             └────────────────────────────────────────────────────────────────────────────┘
```

## 2. The seam contract (what `ven_ao486_shim` must present — from the map)

| group | ao486 port | dir | notes |
|---|---|---|---|
| clk/rst | `clk`,`rst_n` | in | |
| A20 | `a20_enable` | in | address bit-20 gate; **applied inside the core on ao486** — the shim must apply it (Ventium deferred A20) |
| cache | `cache_disable` | in | only gated ao486's L1 icache; **ignore** for Ventium |
| interrupt | `interrupt_do`/`interrupt_vector[7:0]` in, `interrupt_done` out | 8259 level + vector in, INTA pulse out |
| memory | `avm_address[29:0]`(dword),`avm_writedata`,`avm_byteenable[3:0]`,`avm_burstcount[3:0]`,`avm_write`,`avm_read` out; `avm_waitrequest`,`avm_readdatavalid`,`avm_readdata` in | Avalon-MM burst, variable latency; covers DDR + VGA aperture (0xA0000-0xBFFFF) + BIOS shadow (0xC0000-0xFFFFF); routing stays in `l2_cache` |
| dma | `dma_*` (8 wires) | slave | ISA DMA into CPU cache; **tie off idle** initially |
| port I/O | `io_read_do`/`io_read_address[15:0]`/`io_read_length[2:0]`/`io_read_data[31:0]`/`io_read_done`; `io_write_*` | split req/done, byte-count 1/2/4 |

## 3. Ventium side (what the core presents — from the map)

- **Memory:** use the **AXI4 master** (`m_axi_*`, build `+VEN_L1_AXI`, `l1axi_en=1`) =
  `ven_l1d` (8 KB/2-way/32 B L1, same-cycle hit ack) + `ven_axi_master` (read = one
  8-beat INCR burst @4 B; write = single beat, WSTRB verbatim). The raw `mem_*` port
  needs zero-latency and is unusable against real DDR. `ven_axi_master` applies
  `ddr_addr = REMAP_BASE + (phys & ADDR_MASK)` — the shim must set **REMAP_BASE=0,
  ADDR_MASK=0x0FFF_FFFF** (or wider) so the AXI address == guest physical, then the
  bridge does `avm_address = phys[31:2]`.
- **Port I/O:** `io_*` (`io_req/we/addr[15:0]/size[2:0]/wdata/rdata/ack`, `cosim_en=1`)
  — decodes **all** x86 IN/OUT; single-beat, held until `io_ack`.
- **Interrupts:** `intr`(level in)/`inta_vector[7:0]`(in)/`inta`(pulse out),
  `soc_en=1`. Behavioral 8259/INTA (SMI>NMI>INTR, honors IF + STI/MOV-SS shadow).
  Maps ~1:1 to the ao486 seam. `nmi` tied 0.
- **Boot:** `boot_mode=1` → cold reset at CS:EIP=F000:FFF0 real mode → fetches BIOS
  via memory. `init_eip/esp` unused in system mode.
- **FPU:** in-core (`rtl/fpu`), SoftFloat-verified; `+VEN_TRANSCENDENTAL` for FPATAN
  (Quake) etc. (Not the DPI cosim — the full core has its own x87.)

## 4. The three adapters (the net-new RTL in `ven_ao486_shim`)

1. **AXI4 → Avalon-MM bridge** (the big one). AXI read burst (ARLEN=7) → `avm_read`
   with `avm_burstcount=8`; forward 8 `readdatavalid` beats → R channel (RLAST on
   beat 8). AXI single write → `avm_write`,`avm_burstcount=1`,`avm_byteenable=WSTRB`;
   `B` on accept. Hold AR/AW until `avm_waitrequest` low. One outstanding txn to start
   (Ventium issues serially anyway); pipeline later for perf.
2. **I/O split adapter.** `io_req & !io_we` → `io_read_do`, `io_read_length=io_size`,
   `io_read_address=io_addr`; `io_read_done`→`io_ack`, `io_read_data`→`io_rdata`.
   `io_req & io_we` → `io_write_do`/`io_write_data`/`io_write_length`; `io_write_done`
   →`io_ack`. (Confirm `io_size`↔`io_length` encoding: both = byte count 1/2/4.)
3. **Interrupt adapter.** `intr=interrupt_do`, `inta_vector=interrupt_vector`,
   `interrupt_done=inta`. Verify the PIC holds `interrupt_vector` valid through the
   `inta` strobe (it drives it combinationally off level; ao486 PIC does too).
4. **A20 gate.** `phys_a20 = a20_enable ? phys : (phys & ~32'h0010_0000)` on the AXI
   address into the bridge. (Not on I/O — 16-bit ports have no A20.)

## 5. Memory hierarchy & coherency

`Ventium pipeline → ven_l1d (WB L1) → ven_axi_master → [bridge] → avm_ → l2_cache (WB)
→ DDRAM → C++ DDR`. Two coherency concerns carried from the map:
- **R2 — interrupt/IVT & SMC vs write-back L1.** Ventium's interrupt delivery / some
  system reads may bypass `ven_l1d` while guest writes sit dirty in it (a known RTL
  gap that blocked interrupt-driven real-mode guests on KV260 silicon). In Verilator
  the flat DDR *may* hide it, but real-mode boot is interrupt-driven from the first
  `INT`. Mitigations, in order of preference: (a) make `ven_l1d` write-through in the
  sim build; (b) route interrupt/descriptor/IVT reads through L1; (c) targeted flush.
  Decide empirically at POST bring-up.
- **DMA coherency (R1b).** Ventium has no DMA-snoop port. IDE boot is **PIO** (PS
  serves sectors over `mgmt_*`; CPU reads via I/O ports), so no ISA DMA touches the
  cache — tie off `dma_*`. Floppy/SB16 DMA (audio) is off the boot path; revisit only
  if a workload needs it.

## 6. PS/RTL responsibility split (the goal's "clean separation")

- **PL (RTL, in `system.v`):** Ventium core + FPU + L1; `l2_cache`; and *all* ISA
  peripherals with architecturally-visible timing — **8254 PIT, 8259 PIC, RTC, IDE
  register interface, VGA (CRTC + planar mem), 8042/PS2, DMA controller**. Latency and
  cadence are cycle-deterministic in RTL.
- **PS (C++, `ao486-sim/ps` + `sim_main.cpp`):** file-backed / bulk / host-facing
  state only — **disk images (served over `mgmt_*`), BIOS/VGA-BIOS ROM blobs, CMOS
  contents, framebuffer scanout capture, keyboard/mouse injection, clock generation +
  DDR-latency model**. The PS never sees an ISA port access.

This is a *stronger* form of the KV260 split (there, `inb/outb` traps to PS software;
here every ISA port stays in RTL). It is exactly reusable from ao486-sim unchanged.

## 7. Milestone plan (incremental, each self-driven & co-sim'd)

| # | milestone | proof |
|---|---|---|
| A | `ven_ao486_shim` + adapters + patched `system.v` **elaborate + lint** in Verilator | 0 errors |
| B | Ventium **cold-resets at F000:FFF0**, fetches BIOS via `avm_`, retires real-mode insns | eip trace shows BIOS fetch/execute |
| C | **BIOS POST completes** (mem sizing, CMOS, VGA init, IDE detect) self-driven | POST video sign-on; IDE detected |
| D | **DOS boots from IDE** (INT 19h → boot sector → kernel), interrupt-driven | `C:\>` reachable |
| E | **Quake timedemo to completion** | timedemo end / FPS line |
| F | **Win95 to desktop** (reuse the vga.drv fix + dialog dismissals) | desktop PNG |
| G | clean PS/RTL split documented + regression scripts | reproducible runs |

## 8. Build / co-sim

- New RTL: `ao486-sim/ven/ven_ao486_shim.sv` + `ven_axi2avalon.sv` (+ Ventium
  `rtl/ventium.f` files, built with `+VEN_L1_AXI +VEN_KV260_SOC +VEN_TRANSCENDENTAL`).
- `system.v` core-swap via `patches/ao486_MiSTer_vencore.patch` (guarded so the
  existing ao486 build is untouched) or a `+define+VEN_CORE` in a new filelist
  `rtl_ven.f`.
- New sim binary `obj_dir_ven/` reusing the ao486-sim PS (`ps/`, `sim_main.cpp`) with
  a `--ventium` build define; same run flags (`--ide`, `--rate`, `--video-fb`, `--kb`).

## 9. Top risks (from the maturity map) & first-failure watch

1. **AXI↔Avalon bridge correctness** (burst beats, byteenable, ordering) — verify with
   a directed memory test before POST.
2. **Self-driven closed-loop I/O** (PIT/PIC/RTC/IDE-status polling) never run without
   golden replay — the most likely place a real boot diverges from the lockstep runs.
3. **R2 write-back-L1 coherence** on interrupt/IVT/SMC — expected to bite at the first
   real-mode `INT`.
4. **A20 + real-mode wrap** (deferred in Ventium) — needed by BIOS/DOS.
5. **Opcode/system-mode gaps** halt loudly (never silently corrupt) — each is a
   bounded, debuggable stop, not corruption.

*Sources: the integration-surface map (workflow wwk9ksd91) against
`3rd-party/ao486_MiSTer/rtl/{system.v,ao486/ao486.v,cache/l2_cache.v,soc/*}`,
`rtl/ventium_top.sv`, `rtl/mem/ven_l1_axi.sv`+`ven_axi_master.sv`, `docs/rtl-interface.md`,
`README.md`, `PROGRESS.md`, and the ao486-sim PS (`ps/`, `sim_main.cpp`).*
