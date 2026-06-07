# Ventium‑on‑KV260 — an authentic DOS PC that runs Quake

**Status:** active plan (direction locked; synth‑fit probe running). **Target
board:** AMD/Xilinx Kria **KV260** (K26 SOM, `xck26-sfvc784-2LV-c`, Zynq
UltraScale+ MPSoC, ZU5EV). **Toolchain:** Vivado + Vitis **2025.2** at
`/tools/Xilinx/2025.2`; KV260 board files present (`xilinx.com:kv260_som:part0:1.2/1.3/1.4`);
KV260 Vitis base platform present (`xilinx_kv260_base_202520_1.xpfm`).

### Locked decisions
1. **Software target = authentic DOS PC** — boot **FreeDOS** from a real IDE
   disk and run the **DJGPP DOS Quake** (`QUAKE.EXE` + ring‑0 **CWSDPR0** DPMI)
   in **VGA mode 13h**, on the existing `ventium_soc` PC peripherals.
2. **A53 PS runs PetaLinux** as the **I/O processor** (loader + DisplayPort
   scan‑out + USB‑keyboard bridge + reset control) — *not* a syscall server.
3. **Dual‑issue (U/V) from the first fabric build.**
4. Deliver this plan **+ an early synth‑fit/timing probe** on `xck26`.

---

## 0. TL;DR

* The Ventium core is **ISA‑exact and verified against QEMU**, but everything
  around it is a **simulation model**: the only memory port is a 32‑bit valid/ack
  bus served by a **C++ `MemModel`**; the P5 bus carries no real data; the
  D‑cache has no data array; **VGA is a register file with no framebuffer/
  scan‑out**; the IDE disk is a **64 KB `$readmemh` array**; there is **no
  keyboard source, no real clock infra**. Turning this into a DOS PC means
  building the *system around the verified core*.
* The KV260 dictates the shape: **no PL DRAM** (only the PS's 4 GB DDR4, reached
  over `S_AXI_HP/HPC`), **video exits only through the PS DisplayPort**, and a
  **USB‑HID keyboard needs Linux on the PS**. So the **A53 PS is the I/O
  processor**: it loads the BIOS + disk images into a reserved DDR region,
  scans the VGA framebuffer out to DisplayPort, bridges a USB keyboard into the
  i8042, and releases the core.
* **Key simplification:** DOS Quake uses **mode 13h** = a *linear* 320×200×8
  framebuffer at physical `0xA0000`. With **PS‑side scan‑out** (DPDMA + software
  palette‑expand of that DDR region, using the `ven_vgaregs` DAC palette), the
  **PL needs essentially no new VGA datapath** — no CRTC, no planar logic, no
  pixel clock. That removes the single largest RTL item.
* The real work splits into: **(a)** make the core *synthesize and close timing*
  (iterative integer + x87 dividers, BRAM‑inferring icache, `+define+VTM_NO_DPI`),
  **(b)** a **real memory subsystem** (L1 cache + AXI4 master to PS DDR),
  **(c)** finishing the **PC platform** (BIOS, DDR‑backed IDE, i8042 keyboard
  inject + ACK, real‑time PIT/PIC, **un‑gate `INS/OUTS`+`CPUID` under `soc_en`**,
  **x87 transcendentals**), and **(d)** the **PS I/O processor** software.
* **Performance honesty:** ~40–80 MHz fabric after the divider/FPU rework →
  "low‑Pentium, playable‑to‑slideshow" at 320×200, not 60 fps. Ventium's **real
  x87 FPU** is the decisive advantage over 486SX‑class soft cores (on which Quake
  is barely usable).

---

## 1. Success criteria (gated)

1. **Core on fabric** — synthesizable `ventium_soc` runs a tiny program from
   on‑chip BRAM on the KV260 PL; arch state read back over AXI‑Lite matches
   Verilator.
2. **Core from DDR** — fetch/load/store from a reserved PS‑DDR4 region via the
   L1+AXI bridge, bit‑exact vs the sim `MemModel`.
3. **Real‑mode boot** — the (extended) boot firmware/BIOS reaches the IDE,
   chain‑loads a boot sector, and runs it (reuses the existing M9 real‑mode
   chain‑load).
4. **FreeDOS boots** — to a `C:\>` prompt, driven by BIOS `INT 10h/13h/16h/1Ah`
   over the real peripherals.
5. **First Quake frame** — `QUAKE.EXE` sets mode 13h and renders; the PS scans
   the framebuffer to DisplayPort; a recognizable frame appears.
6. **Interactive Quake** — USB keyboard drives the game; it is playable.

---

## 2. What exists vs. what's missing (grounded in the RTL)

### 2.1 The core's one memory boundary
All traffic — fetch, load, store, page‑walk, descriptor/TSS/SMRAM, FP env — uses
one 32‑bit synchronous valid/ack port:

```
out: mem_req, mem_we, mem_addr[31:0], mem_wdata[31:0], mem_wstrb[3:0]
in : mem_rdata[31:0], mem_ack            (core.sv:173-179; ventium_soc.sv:85-91)
```

* One **shared** port; the FSM holds `mem_req` and advances on `if (mem_ack)`.
* Today data comes from a **C++ backdoor** that acks **combinationally, same
  cycle** (`memmodel.cpp:61-83`, `tb_soc.cpp:172-180`). On hardware this is
  absent → the core stalls forever without a real memory.
* The dual‑issue **fast path** reads `mem_rdata` **combinationally the same
  clock** (`core_fastpath.svh`, `core_bus_driver.svh:23`) → it **assumes
  same‑cycle ack**. Real DDR latency must be hidden by a same‑cycle‑ack **L1
  cache**. (The slow FSM tolerates multi‑cycle ack.)
* `biu_p5` is a **protocol exerciser only** — its pins never carry the consumed
  data (`biu.sv:31-43`). **Attach DDR at `mem_*`, not at `biu_p5`.**
* `ventium_soc` already muxes the `mem_*` port between the **core** and the
  **IDE bus‑master DMA** (`ventium_soc.sv:202-213`), and applies the **A20 mask**
  to the core address — the natural place to insert a real arbiter + AXI bridge.

### 2.2 Interrupt + I/O wiring (already present in `ventium_soc`)
* PMIO decode (`ventium_soc.sv:318-356`): PIC `0x20/0xA0/0x4D0`, PIT `0x40-0x43`,
  RTC `0x70/0x71`, i8042 `0x60/0x64`, port‑92 `0x92`, VGA `0x3B0-0x3DF`, ACPI
  `0x608`, IDE `0x1F0-0x1F7/0x3F6` (+secondary), PCI `0xCF8/0xCFC`, BMIDE @BAR4.
* IRQ fabric: `pic_irq_in[0]=PIT, [1]=kbd, [8]=rtc, [12]=mouse, [14/15]=ide`;
  `pic.int_out→core.intr`, `core.inta→pic`, `pic.inta_vector→core`
  (`ventium_soc.sv:135-167,375-387`). Only IRQ0 is exercised in sim today.

### 2.3 Synthesizability gaps to fix
| Item | Where | Fix |
|---|---|---|
| DPI retire imports/calls | `ventium_pkg.sv:62-163` + call sites (guarded `\`ifndef VTM_NO_DPI`) | build with **`+define+VTM_NO_DPI`** |
| `$readmemh` disk; 1 unguarded `initial` ROM | `ven_ide.sv:327` (guarded), `:337` (ROM) | replace disk backing (§6.5); confirm ROM infers |
| **Combinational integer DIV/IDIV** (`/`,`%`, ≤64‑bit) | `core_exec.svh:264-339` | **iterative divider** (worst path) |
| **Combinational x87 FDIV** (192/128‑bit) | `fpu_x87_pkg.sv:261` | **iterative FSM** (reuse `fx_srt_div`, NSTEP=36) |
| **Combinational x87 FSQRT** (128‑iter/256‑bit) | `fpu_x87_pkg.sv:661,703` | **iterative FSM** |
| FMUL 64×64 + normalize in 1 clock | `fpu_x87_pkg.sv:203,217` | DSP‑mapped **pipelined** multiplier |
| **icache exposes whole array combinationally** | `icache.sv:60,101-117` | **registered BRAM read port** |
| no PLL/reset infra; sim‑tuned tick params | `ventium_soc.sv` clk/rst; PIT/RTC/ACPI | MMCM + reset sync; **retune ticks to fabric clock** |

Otherwise clean: **no** `$finish/$fatal/$random/$time/real/SVA/force/fork/#delay`
in synthesizable paths.

#### 2.3a Vivado‑vs‑Verilator cleanliness (found by the synth probe — already fixed)
The Verilator‑based sweep missed constructs Verilator accepts but **Vivado synth
rejects**. The synth‑fit probe surfaced (and these are now patched, all
behavior‑preserving, Verilator‑still‑green):
* **Bit‑select on a function‑call result** (`f(x)[i]`) — IEEE 1800 illegal;
  Vivado errors. Fixed by binding to a temp: `ventium_x87_pkg.sv` (`fx_is_snan`),
  `core_exec.svh` (`K_BITTEST`).
* **`input logic` ports under `\`default_nettype none`** — Vivado requires a
  *net* type (`input wire`). Fixed 33 input ports → `input wire logic` across
  `ventium_soc.sv`, `ven_pic.sv`, `ven_i8042.sv`, `ven_rtc.sv`, `ven_port92.sv`
  (function args left as `input logic`).
* **Variable‑bound loops** Vivado can't statically unroll (“loop condition does
  not converge”): the BSF/BSR `for (i=hi…)` (`core_exec.svh`, → constant bound +
  `i<=hi` guard) and the 8259 priority `while` (`ven_pic.sv`, → bounded `for` +
  found‑flag). All other loops use compile‑time params (fine).

This is a recurring class: a **“make it Vivado‑clean” pass** is a standing
sub‑task of synth‑subset hardening; keep `make verify` green after each fix.

### 2.4 DOS‑specific functional gaps (must implement for Track B)
* **`INS/OUTS` and `CPUID` are gated OFF under `soc_en` → HALT.** A real BIOS
  `INT 13h` sector read commonly uses `REP INSW` from `0x1F0`, and DPMI/Quake may
  use `CPUID`. **These must be un‑gated** (the instructions already exist; they
  were verified in user/cosim mode). *Blocker for disk I/O.*
* **x87 transcendentals are absent → HALT** (`core.sv:1916`,
  `docs/m3-fpu-spec.md:50`). DOS Quake's math (e.g. `VectorAngles`→`atan2`→
  `FPATAN`, possibly `FSIN/FCOS`) will hit them. **Must implement** (CORDIC/poly
  micro‑sequences over the existing primitives). *Top FPU risk — confirm the
  exact opcode set with a timedemo trace.*
* **VGA:** `ven_vgaregs` holds SEQ/GFX/CRTC/ATTR + the **256×3 DAC palette**, but
  has **no framebuffer, scan‑out, or palette→RGB output** (`ven_vgaregs.sv`).
  For **mode 13h (linear)** this is fine: the framebuffer is plain RAM at
  `0xA0000` and the **PS does scan‑out** — we only need the **palette readable by
  the PS** (add a read port / expose via AXI‑Lite) and the IS1 `0x3DA` retrace
  bit good enough for Quake's wait loop (the existing dumb toggle suffices, or
  drive it from a PS‑provided vsync).
* **IDE disk is 64 KB BRAM** (`ven_ide.sv:323`); Quake+FreeDOS need ~16–32 MB.
  **DDR‑back the disk** and scale geometry; verify **multi‑sector PIO** (the BIOS
  path). DMA optional.
* **i8042 has no keyboard source** (`ven_i8042.sv`): no scancode input, no
  command **ACK (0xFA) queue** → OS keyboard init would hang. Add a **scancode
  inject port** (load `cbdata`, set OBF, raise IRQ1) + a minimal ACK queue.
* **PIT/PIC real‑time:** IRQ0 cadence must match 1.193182 MHz from the fabric
  clock (set `TICK_DIV`); ensure the PIC→core INTR/INTA delivery actually fires
  under load (only IRQ0 connectivity is sim‑verified).
* **BIOS:** the core resets to `F000:FFF0`; a 16‑bit BIOS (INT 10h/13h/16h/1Ah/
  15h + VGA BIOS mode‑set/palette) must live at `0xF0000-0xFFFFF`. Reuse/extend
  the existing **M9 real‑mode chain‑load firmware**; **SeaBIOS+SeaVGABIOS**
  (what QEMU uses, so closest to the verified target) is the reference/fallback.

---

## 3. Target platform facts (KV260 / XCK26)

* **PL:** ~117 K LUTs, ~234 K FFs, **144× BRAM36 (~5.1 Mb)**, **64× URAM (18
  Mb)**, **1248 DSP48E2** (≈2.8 MB on‑chip — DDR is mandatory for Quake).
* **PS:** quad **A53** (to 1.5 GHz), dual R5F, **4 GB DDR4** (PS‑only; **no PL
  DRAM**). **PL→DDR:** `S_AXI_HP0-3` (non‑coherent) / `S_AXI_HPC0-1` (coherent,
  CCI‑400), 32/64/128‑bit, ~3–8.5 GB/s/port. **PS→PL:** `M_AXI_HPM0_FPD`
  AXI‑Lite (≈`0xA000_0000`). PL clocks/`pl_resetn` from the PS.
* **Video:** only via PS DisplayPort (DP `J6` + HDMI `J5` from one PS DP source
  via STDP4320). DPDMA scans an **RGB** framebuffer from DDR (**no CLUT/indexed**
  mode → 8bpp must be expanded in PS software). Target **640×480@60** (2× upscale
  of 320×200, or 640×400 letterboxed) for monitor compatibility.
* **USB:** 4× USB3 on one PS controller; **USB‑HID host = Linux only** → PetaLinux.
* **Boot:** QSPI `BOOT.BIN` (FSBL+PMUFW+ATF+U‑Boot) → microSD (kernel+rootfs+
  bitstream); PL loaded at runtime via **`xmutil loadapp`** (`<app>.bit.bin` +
  `.dtbo` + `shell.json`).

---

## 4. Architecture

```
        ┌──────────────────────── KV260 (XCK26 MPSoC) ─────────────────────────┐
        │  PS (quad A53, PetaLinux) = I/O PROCESSOR     PL (FPGA fabric)         │
        │  ┌─────────────────────────────┐  AXI-Lite   ┌─────────────────────┐  │
        │  │ loader: BIOS ROM + FreeDOS/  │  (HPM0)     │ ventium_axil_ctrl   │  │
        │  │  Quake disk image → DDR      │────────────▶│ reset/run, palette  │  │
        │  │ display: read A0000 framebuf │◀────────────│ read, kbd inject,   │  │
        │  │  + DAC palette → expand→RGB  │             │ arch peek, hung     │  │
        │  │  → 640x480 → DPDMA → monitor │             └─────────┬───────────┘  │
        │  │ input: USB-HID → Set-1 scan  │             ┌─────────▼───────────┐  │
        │  │  → kbd inject reg            │             │   ventium_soc        │ │
        │  │ control: release pl reset    │             │  core(U/V) + x87 +   │ │
        │  └──────────────┬──────────────┘             │  PIC/PIT/RTC/8042/   │ │
        │                 │                            │  port92/VGAregs/ACPI/ │ │
        │        ┌────────▼─────────┐  S_AXI_HPC0      │  IDE  + A20 + IRQ     │ │
        │        │  4 GB DDR4 (PS)  │◀─────────────────│   mem_* 32b v/ack     │ │
        │        │  reserved window:│  S_AXI_HP0       └─────────┬───────────┘  │
        │        │  • BIOS @F0000   │◀───────┐        ┌──────────▼───────────┐  │
        │        │  • RAM 0..16-32M │        └────────│ ventium_l1_axi       │  │
        │        │  • VGA fb @A0000 │◀────────────────│ L1$(BRAM)+AXI master │  │
        │        │  • disk image    │   (IDE reads)   │ +CDC +base remap +A20│  │
        │        └──────────────────┘                 └──────────────────────┘  │
        └───────────────────────────────────────────────────────────────────────┘
```

The **whole x86 physical address space lives in one reserved DDR window** (flat
map via a base offset in the bridge): conventional RAM, the VGA framebuffer at
`0xA0000` (read by the PS for scan‑out), extended memory for Quake, the BIOS at
`0xF0000`, and the IDE disk image (a separate sub‑region the IDE controller reads
via AXI). The core boots real‑mode at `F000:FFF0`, FreeDOS runs, DPMI enters
flat 32‑bit protected mode (paging off, A20 on), and Quake renders into the
`0xA0000` framebuffer that the PS continuously blits to DisplayPort.

---

## 5. RTL work plan (PL)

### 5.1 Synth‑subset hardening
`+define+VTM_NO_DPI`; tie off sim‑only ports; **iterative integer divider**
(`core_exec.svh`); **BRAM‑inferring icache**; un‑gate `INS/OUTS`+`CPUID` under
`soc_en`.

### 5.2 `ventium_l1_axi` — real memory subsystem *(linchpin)*
Unified **L1 cache** (BRAM/URAM tags+data) giving **same‑cycle ack on hit** (so
the dual‑issue fast path works) and AXI4 bursts on miss; **CDC** core↔AXI clock;
**base‑offset remap** (x86 phys → reserved DDR) + **A20** handling; `wstrb`
passthrough + full‑aligned‑word reads. Sits where `ventium_soc.sv:202-213` muxes
core/IDE‑DMA today. Connect to **`S_AXI_HPC0`** (coherent — the PS writes images
and reads the framebuffer). Bring‑up: BRAM scratchpad → direct AXI (fast‑path
off) → cached AXI.

### 5.3 `ventium_axil_ctrl` — PS control (AXI‑Lite slave, `HPM0`)
reset/run, `init_eip/init_esp`, `boot_mode`; **DAC‑palette read** + **mode/fb
status** for the PS scan‑out; **keyboard scancode inject**; **arch‑state peek** +
retire counter + `cpu_hung` (reuse retire snapshot, expose via regs not DPI).

### 5.4 x87 for hardware
Iterative **FDIV/FSQRT**, pipelined **FMUL/FADD** (drive the existing
`fp_ready_cyc/fp_occ` scoreboard from real "done"); implement **transcendentals**
(CORDIC/poly) at the deferred‑decode arm (`core.sv:1916`).

### 5.5 PC peripherals (extend `ventium_soc`)
* **VGA:** expose the `ven_vgaregs` DAC palette to the PS (read port / AXI‑Lite);
  ensure `0xA0000` framebuffer is plain DDR; keep IS1 `0x3DA` retrace usable. *(No
  CRTC/planar/scanout RTL needed for mode 13h.)*
* **IDE:** replace `disk[]` `$readmemh` with **DDR‑backed reads** (PIO mux
  `ven_ide.sv:414`, DMA copy `:469-470`); scale `DISK_SECTORS`/geometry/OOR
  checks; verify multi‑sector PIO.
* **i8042:** add scancode **inject port** + IRQ1 raise + a minimal **ACK queue**.
* **PIT/RTC/ACPI:** set tick params from the chosen fabric clock for real‑time
  IRQ0 / 1 Hz / 3.579545 MHz; verify PIC→core delivery under load.
* **Clock/reset:** MMCM (core clock + AXI clock) + reset synchronizer; `pl_resetn`
  from the PS.

### 5.6 Firmware/BIOS
Extend the existing **M9 real‑mode chain‑load firmware** into a BIOS providing
`INT 10h` (mode 13h set + DAC palette + font), `INT 13h` (IDE), `INT 16h`
(keyboard), `INT 1Ah` (PIT/RTC), `INT 15h` (memory map/A20); use
**SeaBIOS+SeaVGABIOS** as reference/fallback (QEMU‑matched). Mapped at `0xF0000`.

---

## 6. PS software (PetaLinux "I/O processor")

A user‑space app (the hardware analog of `tb_soc.cpp` + a south‑bridge):
1. **Bring‑up:** `mmap` the reserved DDR window + the PL `HPM0` window; hold the
   core in reset.
2. **Load:** copy the BIOS ROM image to `0xF0000`, the FreeDOS+Quake disk image
   to the IDE sub‑region; flush caches (or rely on HPC coherency); set
   `boot_mode=1`, release the core.
3. **Display loop:** read the `0xA0000` framebuffer + DAC palette; expand
   8bpp→RGB888, 2× upscale to 640×480 into a double‑buffered DDR framebuffer;
   **DPDMA** scan‑out at 640×480@60.
4. **Input:** USB‑HID (evdev) → i8042 Set‑1 make/break → inject register.
5. **Console/debug:** UART log; arch‑state peek; `cpu_hung` watch.

PetaLinux project: reserved‑memory node for the DDR window (dma‑coherent if HPC),
the PL device‑tree overlay (HPM0 window), USB host + DisplayPort enabled.

---

## 7. `./fpga` folder layout

```
fpga/
  PLAN.md                       ← this file
  rtl/
    ventium_kv260_top.sv        ← PL top: ventium_soc + L1/AXI + AXI-Lite ctrl + MMCM/reset
    ventium_l1_axi.sv           ← L1 cache + AXI4 master + CDC + remap/A20   (§5.2)
    ventium_axil_ctrl.sv        ← AXI-Lite control/palette/kbd/peek slave    (§5.3)
    ven_ide_ddr.sv (or patch)   ← DDR-backed disk for ven_ide                (§5.5)
    synth_defs.svh              ← +define overrides / tie-offs
  firmware/
    bios/                       ← extended M9 firmware / SeaBIOS integration  (§5.6)
    disk/                       ← FreeDOS + DOS Quake (pak0.pak) image builder
  constraints/
    probe.xdc                   ← synth-probe clock (done)
    ventium_kv260.xdc           ← real constraints (clocks; few/no PL pins)
  scripts/
    synth_probe.tcl             ← fit/timing probe (done)
    build.tcl / bd.tcl          ← in-memory Vivado flow: zynq_ultra_ps_e + smartconnect
    package_firmware.sh         ← bootgen .bit.bin + createdts/.dtbo + shell.json
  ps/
    io-proc/                    ← A53 app: loader + DP scan-out + USB-kbd bridge
    petalinux/                  ← config, device-tree (reserved-memory, overlay)
  sim/
    tb_axi_mem.*                ← cosim of core+L1+AXI vs MemModel
  build/                        ← gitignored (.xsa/.bit/.bit.bin/.dtbo, synthprobe/)
  Makefile
```

Vivado flow: in‑memory / non‑project, Tcl‑scripted (mirrors the repo's
artifact‑vs‑source discipline; `build/` gitignored). Board part
`xilinx.com:kv260_som:part0:1.4` (installed) or the Vitis base platform.

---

## 8. Verification strategy

* **Keep the sim gates green:** every synth‑subset edit (iterative divider/FPU,
  BRAM icache, `INS/OUTS`+`CPUID` un‑gate, transcendentals) must stay bit‑exact
  in Verilator before going to fabric (`make verify`, `make verify-sys`, `make m3`).
* **New blocks cosim'd:** core+L1+AXI vs `MemModel`; IDE‑from‑DDR vs the
  `gen_disk.py` image.
* **Platform bring‑up vs QEMU:** FreeDOS+Quake under `qemu-system-i386 -cpu
  pentium` with SeaBIOS is the golden environment; compare boot/render behavior.
* **On hardware:** AXI‑Lite arch‑peek + retire counter + `cpu_hung`; ILA on
  `mem_*`/AXI for first bring‑up; PS UART console.

---

## 9. Milestones (each ends with a gate)

* **F0 — Vivado scaffolding.** `./fpga` skeleton; in‑memory Tcl build of PS + a
  pokeable PL register; load via `xmutil`. *Gate:* PS reads/writes a PL register
  on the board. *(synth‑fit probe informs Fmax/area targets — running now.)*
* **F1 — Core on fabric (BRAM).** Synth‑subset hardening; run a tiny x86 program
  from on‑chip BRAM. *Gate:* PL core retires it; AXI‑Lite arch peek matches
  Verilator; timing closes at the chosen Fmax (dual‑issue).
* **F2 — Core from DDR.** `ventium_l1_axi` → `S_AXI_HPC0`; reserved DDR; PS loads
  an image. *Gate:* memory‑heavy test bit‑exact vs `MemModel` cosim, on hardware.
* **F3 — Real‑mode boot + FreeDOS.** BIOS at `0xF0000`; DDR‑backed IDE; un‑gated
  `INS/OUTS`; real‑time PIT/PIC; i8042 inject. *Gate:* FreeDOS reaches `C:\>`,
  keystrokes echo (UART‑injected first, then USB).
* **F4 — First Quake frame.** Transcendentals done; `QUAKE.EXE -nosound -stdvid`
  sets mode 13h; PS scan‑out → DisplayPort. *Gate:* a recognizable frame.
* **F5 — Interactive.** USB‑HID keyboard; tune L1/clock for framerate. *Gate:*
  Quake playable on the KV260.

---

## 10. Top risks & mitigations

* **Timing/area (dual‑issue P5+x87 on ~117 K LUTs).** **Baseline measured** (see
  `fpga/TIMING_PROBLEMS.md`): the as‑is core is **517 % LUTs** and **~3.6 MHz**,
  entirely due to the combinational FPU/divide and FF‑mapped caches — FF (39 %)
  and DSP (32 %) fit. Iterative dividers/sqrt, pipelined FMUL, and BRAM caches are
  what make it *fit at all*; re‑probe after each. Keep a single‑issue fallback.
* **DDR latency.** The L1 cache is mandatory; size generously in URAM.
* **Coherency PS↔PL.** Use `S_AXI_HPC` (CCI‑400) for the shared window.
* **x87 transcendentals at runtime.** Confirm the exact opcode set via a timedemo
  trace; implement CORDIC/poly; this is the top FPU effort.
* **`INS/OUTS`/`CPUID` HALT under `soc_en`.** Un‑gate early (F3 blocker).
* **BIOS completeness / SeaBIOS hitting an unimplemented opcode or I/O → HALT.**
  Iterative "fix the next loud HALT"; start from the minimal M9 firmware.
* **DPDMA has no CLUT.** PS does palette‑expand (planned).
* **Disk size / multi‑sector PIO.** DDR‑back + scale geometry; verify the BIOS
  `REP INSW` path.

---

## 11. Immediate next steps
1. **Synth‑fit probe** (running) → utilization + estimated Fmax of as‑is
   `ventium_soc`; record in `fpga/build/synthprobe/` and summarize here.
2. Confirm the **x87 transcendental opcode set** DOS Quake actually issues (QEMU
   timedemo trace).
3. F0 scaffolding (Vivado Tcl flow + a trivial PL register + `xmutil` load).
4. Begin synth‑subset hardening (iterative integer divider; BRAM icache;
   `VTM_NO_DPI`; un‑gate `INS/OUTS`+`CPUID`) keeping `make verify` green.
```
