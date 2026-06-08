<!--
Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
-->
# Ventium pipeline visualizer

An interactive PySide6 GUI that runs the **real verilated Ventium RTL** as its
backend and visualizes, cycle by cycle, what the core is doing: the three
pipelines (U / V integer dual-issue + the x87 FP pipe), what's resident in the
TLB / code cache / data cache / prefetch buffer, and the retired-instruction
trace with raw bytes and disassembly.

It does **not** modify `rtl/` or the verification build — it verilates a private
copy of `ventium_top` with `--public-flat-rw` so the C++ bridge can read every
internal core/cache/TLB/FPU signal directly out of the model (a cross-module
reference into the live RTL state), and drives the exact `clk`/reset/`mem_*`
loop the production testbench (`verif/tb/tb_main.cpp`) uses.

![overview](docs/overview.png)

## Quick start

```sh
# build the backend (verilate + link libventium_viz.so) and launch the GUI
tools/pipeviz/run.sh

# user-mode examples
tools/pipeviz/run.sh build/m2/mb_brloop.flat         # dual-issue loop
tools/pipeviz/run.sh build/m2/mb_dmiss.flat          # D-cache thrash (fills the D$)
tools/pipeviz/run.sh build/m2/mb_imiss.flat          # I-cache misses (fills the I$)
tools/pipeviz/run.sh build/m2/mb_fpindep.flat        # x87 FP pipe
tools/pipeviz/run.sh build/m2/mb_brrandom.flat       # random-branch mispredicts

# system / paging examples (slow-path waterfall + TLB + page walks)
tools/pipeviz/run.sh verif/sys/tests/ppage/ppage.bin
tools/pipeviz/run.sh verif/sys/tests/ptask/ptask.bin

# full-SoC bare-metal test (needs the SoC port-I/O): the test386.asm CPU test.
# build the SoC model once, then load it (auto-detected as a SoC image):
tools/pipeviz/build.sh --soc
tools/pipeviz/run.sh ventium-refs/09-external-cpu-tests/test386.asm/test386.bin

# force a rebuild of the backend (add --soc to also build the SoC model)
tools/pipeviz/run.sh --build
```

Requirements (all already present in this repo's toolchain): `verilator` (5.x),
a C++17 compiler, `python3` with **PySide6** and **capstone**
(`pip install PySide6 capstone`).

## What you see

The window is four linked panels (see the screenshot above): the **Pipelines**
panel (top-left), the **analysis tabs** (top-right), the retired-instruction
**Trace** (bottom-left), and the **Registers** (bottom-right), with a grouped
**status bar** along the top.

* **Pipelines panel** (top-left)
  * *Stage board* — the classic P5 in-order stages **PF → D1 → D2 → EX → WB**
    (plus the FP **X1 / X2 / WF / ER** stages) as **U / V / FP** lanes. The
    cell(s) the core is working in this clock are lit and labelled with the
    occupying instruction. Derived live from the FSM `state` in `rtl/core/core.sv`.
  * *Pipeline view* — a **gem5/Konata-style** per-instruction timing diagram:
    **Y = instructions** (one row each, retire order), **X = cycles** (time →).
    Each lifecycle is reconstructed from the per-cycle FSM trace as a run of
    coloured, glyphed stage cells — **F** fetch, **L** I-cache fill, **D** decode,
    **X** execute (green integer / purple x87), **M** mem, **W** writeback,
    **=** stall, **!** mispredict-flush, **S** sys/microcode — so consecutive
    instructions cascade diagonally (the classic superscalar diagram); a stalled
    instruction stretches (a D-cache miss is a long `=N` run before its `X`). A
    frozen gutter holds the labels (n / U·V pipe / PC / mnemonic) + a colour-graded
    **latency badge** (`Nc`, red when heavy). **Interactive analysis:** click an
    instruction (cell or trace row) to **pin the registers AS-OF that retirement**,
    drop a cyan cycle **playhead**, and draw **producer→consumer dependency edges**
    (a line from each source register's writer; the flag-edge for a conditional
    branch; amber+thick when it's the gating load-use that lifted a stall). It also
    **PC-group-highlights** every other execution of the same PC (loop iterations).
    **Shift-click** a second row for a **Δ-measure band** (latency between two
    instructions). A red **"stuck"** banner overlays if the core wedges in a
    front-end / halt state.
  * *IPC / stall sparkline* — a windowed IPC track (0/1/2 axis) with per-cycle
    event pixels (mispredict / stall / I-fill / page-walk) that doubles as a
    **clickable seek bar** for the playhead.
* **Analysis tabs** (top-right) — ten tabs over the live microarch state:
  * **Code$ / Data$** — resident cache lines + a **256-cell set×way occupancy
    heatmap**; the Data$ header also reports a **replayed miss-rate** (the resolved
    access stream run through a client-side 2-way-LRU model matching the hardware
    `dcache_timing` geometry, so it names the cause of the load-stall bubbles).
  * **TLB** — valid split I/D entries (only populated under paging).
  * **Prefetch** — the `ibuf[16]` + the fast-path fetch window, with a live decode.
  * **Hotspots** — a per-PC cycle-cost profile (perf/VTune-style; stalls inflate
    cost so the slow PCs bubble up), with a **D$ miss** column attributing the
    replayed misses to each load/store PC.
  * **Branches** — a per-branch-PC BTB profile (type / target / hits / taken% / bias).
  * **Instr mix** — an instruction-class histogram + the realised **U/V dual-issue**
    split.
  * **Cycles** — a **cycle-attribution** breakdown (every cycle classified by FSM
    state: retire / issue-stall / mispredict / I-fill / decode / load-store /
    page-walk / x87 / system / halt), so the tallest bar is the bottleneck.
  * **Memory** — a hex/ASCII inspector (type an address, or follow EIP / ESP / the
    most-recent load-store **access**, which gold-outlines the touched bytes).
  * **Mem map** — an **address-vs-retire-order scatter** of the load/store stream
    (a strided walk reads as a diagonal, a hot location as a band) with the dominant
    stride; **click a point** to jump the trace + Registers + Memory tab to it.
* **Trace panel** (bottom-left) — one row per retired instruction: `n`, retire
  cycle, **Δ** (stall gap), pipe (U/V), PC, raw **bytes** (coloured by x86 field:
  prefix gray / opcode blue / ModRM green / SIB purple / displacement gold /
  immediate salmon / branch-rel orange), the **disassembly** (field-coloured to
  match, 16/32-bit per the live CS.D), and an **effect** column showing what each
  instruction architecturally *wrote* — destination GPR + committed value (blue),
  changed flags (teal), x87 ST(0) result (purple), x87 exceptions (amber), and the
  resolved memory-access address of a load/store (gold). A **filter box** accepts
  `mov` / `pc:08048` / `cyc>=133` / `pipe:V` / `stall` / `@` (memory-accessing rows).
* **Registers panel** (bottom-right) — GPRs, **EFLAGS** as a named-bit grid (set =
  amber, changed underlined), segments, control registers, and the **x87 stack**
  (logical ST(0..7) with the 80-bit hex split sign/exp ␣ mantissa + decoded
  `floatx80`). Values that changed this step are amber; the panel can be **pinned
  AS-OF a retired instruction** (click a trace row / Konata cell) — an amber
  `PINNED n=… cyc=…` banner shows that instruction's post-commit state.
* **Status bar** — `cyc` · FSM state/mode · `ret` / `IPC` / dual-issue `pair%` /
  `mispred` · I$/D$ occupancy / I-cache `fills` / page-table `walks` · `eip`.

## Controls

| control | action |
|---|---|
| **Open image…** | load a flat binary (honours a sibling `manifest.json` for `entry`/`load_addr`) |
| entry / load / esp | reset-time architectural state (hex) |
| **cycle (dual-issue)** | enable the U/V fast path — **on by default** (the V pipe only issues in cycle mode) |
| **system** | cold-boot in system mode (real-mode reset at `F000:FFF0`; needed for paging/TLB) |
| **SoC** | run the full `ventium_soc` (internal port-I/O / PIC / PIT) — needed for bare-metal images like test386. Requires `build.sh --soc`; auto-ticked for test386. |
| **Reset** | re-cold-reset on a fresh model (clears memory) |
| **Step clk** (`.`) | advance one core clock |
| **Step insn** (`i`) | advance until the next retirement |
| **Step N** | advance N clocks |
| **Run / Pause** (`F5`) | free-run at *speed* clocks per refresh tick |
| **event** ◀ / ▶ (`[` / `]`) | jump the playhead to the prev / next pipeline event (mispredict / stall / I-fill / page-walk) |

Mouse interactions: **click** a Konata cell or a trace row to pin the registers
to that instruction and drop a cycle playhead (the trace ↔ pipeline selection is
two-way); **shift-click** a second Konata row to measure the cycle Δ between two
instructions; **click** a point in the **Mem map** to jump the trace + Memory tab
to that load/store; **click** the IPC sparkline to seek the playhead. Stepping
unpins the registers back to the live state.

## Architecture

```
 PySide6 GUI (pipeviz/*.py)
   │  ctypes
   ▼
 libventium_viz.so  ── C ABI (ventium_viz.h)
   │  wraps + drives
   ▼
 Vventium_top  ── verilated --public-flat-rw  (rtl/ventium.f, unmodified)
   └── internal state read via the generated ___024root struct
       (u_core.state / ibuf / u_d,v_d / gpr / u_icache / u_dcache_tm /
        u_itlb / u_dtlb / u_fpu_state / …)
```

* `ventium_viz.cpp` — the bridge: instantiates the model, reuses the production
  BFM memory (`verif/tb/memmodel.cpp`), implements the `vtm_retire*` DPI
  callbacks to capture each retirement into a ring buffer, samples per-clock
  microarch state into a timeline ring, and exposes everything over a flat C ABI.
* `pipeviz/backend.py` — ctypes mirror of the C ABI (with a `sizeof` self-check).
* `pipeviz/disasm.py` — capstone disassembly + the FSM-state → pipeline-stage map.

## Notes on fidelity

* The Ventium core is FSM-driven, not a textbook latch-per-stage superscalar, so
  the stage board maps each FSM `state` to the P5 stage it corresponds to rather
  than inventing per-stage instruction latches. The timeline shows the genuine
  emergent cadence (issue, stalls, fills, FP occupancy).
* The **U/V dual issue** only activates in **cycle mode** (default on); in func
  mode the core is single-issue. **FP** ops appear on the FP lane.
* The **TLB** only fills when paging is active — load a system/paging image and
  tick **system** to see I/D TLB entries. In flat user mode it stays empty (no
  translation), which is correct.
* The D-cache is a timing-only model in the RTL (tag/valid/LRU, no data array),
  so its table shows residency, not bytes.

## Files

| file | role |
|---|---|
| `build.sh` | verilate `--public-flat-rw` + link `libventium_viz.so` |
| `run.sh` | build-if-needed + launch the GUI |
| `ventium_viz.h` / `.cpp` | the C ABI + Verilator backend bridge |
| `pipeviz/` | the PySide6 application |
| `smoke_test.c` | minimal C end-to-end check of the C ABI |
| `verify_gui.py` | offscreen GUI smoke + screenshot |
