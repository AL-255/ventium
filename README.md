# Ventium

<p>
  <img src="docs/ventium.png" alt="Ventium" width="440">
</p>

An RTL reconstruction of the original Intel **Pentium (P5 / P54C, non-MMX)**
microarchitecture, written in synthesizable SystemVerilog, simulated with
**Verilator**, and verified differentially against **QEMU**. It is **ISA-exact
and cycle-approximate for the broad subset it verifies** — high fidelity as an
architectural + cycle model, medium fidelity as a full microarchitectural / pin-
level clone (see [`docs/isa-coverage.md`](docs/isa-coverage.md)
/ [`docs/modeled-by-effect.md`](docs/modeled-by-effect.md)).

- **Sphinx Documentation:** <https://al-255.github.io/ventium/>
- **Reference Material + Benchmark Programs: (Private)** [`ventium-refs/`](ventium-refs/) submodule
  (Intel manuals, Alpert & Avnon, Agner Fog, datasheet, spec updates, and a
  working QEMU `-cpu pentium` functional + cycle golden harness). This submodule contains proprietary material, so it is not public; the reference material is cited in the design docs and the code comments, and the QEMU harness is described in `verif/qemu-trace/`.

## What's implemented

- **Integer core:** a 5-stage in-order **dual-issue (U/V)** pipeline (PF/D1/D2/EX/WB). With correct pairing rules.
- **Pipelined x87 FPU:** Implemented using ROM constants discovered by Ken Shirriff's reverse engineering. The SRT divider is able to faithfully reproduce the P5's infamous FDIV bug.
- **Memory:** 8 KiB / 2-way / 32 B split L1 I/D caches (LRU), split 16-entry I/D
  TLBs, and the 2-level paging MMU (A/D bits, 4 KiB + 4 MiB pages).
- **System mode:**  cold reset → real mode → protected-mode segmentation →
  paging → IDT-delivered interrupts/exceptions + `IRET`, TSS + cross-privilege +
  the **hardware task switch**, **SMM / `RSM`**, **debug registers + `#DB`**, and
  **virtual-8086** mode.
- **Errata:** documented P5 silicon errata (FDIV, FIST, F00F, MOV-moffs, the V86
  `POPF`/`IRET` `#DB`) reproduced behind a default-off flag, self-checked against
  the Intel Specification Updates (never against QEMU, which computes correctly).
- **Macro-workload lock-step (M7)** -- real programs run on the RTL in lock-step
  vs QEMU: **Quake** is bit-exact over **~1.1M instructions**, and a **Windows 95
  boot** is bit-exact to **213,859 instructions** (input-replay: QEMU is the golden
  + environment, the RTL is the checked CPU). This found + fixed **6 real ISA gaps**
  (`TEST r/m,imm` mem-form, `call gs:[]`, `LOCK CMPXCHG`, `IN`/`OUT`, `CPUID`, `INS`).
- **FPGA full-SoC implementation:** WIP - Targeting KV260 (Xilinx ZU5EV equivalent). The L1$ and peripherals are partially implemented in the PS to save FPGA resources, but the core + FPU are fully RTL.
- **PipeViz Visualizer:** A Custom PyQt5-based trace visualizer.

## Layout

```
rtl/                synthesizable SystemVerilog
  core/               the pipeline spine (core.sv) + ALU/decode packages,
                      the variable-length decoder, U/V issue, bpred_btb
  fpu/                x87 FPU — the 80-bit datapath package (+ state file)
  mem/                dcache_timing / icache / tlb
  bus/                biu_p5 pin-level 64-bit bus + the gated bus subsystem
  soc/                PC peripheral device models (PIC/PIT/RTC/i8042/port92/
                      acpipm/vga) — the M8 self-contained-SoC track
  ventium_top.sv      the verification top (core + leaf modules)
verif/
  qemu-trace/         gen_trace.py — golden architectural-state trace via the
                      QEMU gdbstub (-g); --system + the syscall/replay proxies
  tb/                 Verilator C++ testbench + bus-functional memory + DPI retire
  diff/               compare.py / compare_stream.py (O(1) memory) + tracefmt.py
  bench/              standard-benchmark differential harness (deep lock-step +
                      free-run syscall-emulation; coremark/whetstone/.../Quake)
  sys/                bare-metal system-mode tests + qemu-system goldens
  m7/                 Quake + Win95 lock-step harnesses
  soc/                device-module unit self-checks
  bus/                biu_p5 standalone self-consistency + 19 SVA gate
  errata/             errata self-checks (make m6)
docs/               trace-format.md (the producer/consumer contract), the
                    m*-spec.md design docs, and sphinx/ (the live catalog)
3rd-party/          opl3_fpga submodule (OPL3 FM synth, for a SoundBlaster card)
```

## Build & verify

```bash
git submodule update --init --recursive    # ventium-refs + 3rd-party/opl3_fpga

make verify          # fast differential gate (~2 s warm): user-mode functional
                     # + the M4/M5 cycle bands, parallelised + golden-cached
make verify-sys      # system-mode gates (pseg/pmode/ppage/pintr/pfault/pcpl/
                     # ptask/pdebug/pv86 + psmm structural)
make m1 m2 m3 m4 m5 m6    # per-milestone gates (m3 = x87, m6 = errata behind a flag)

# macro-workload lock-step (oracle-bound prefixes; see docs/m7-lockstep-spec.md):
bash verif/m7/run-quake-lockstep.sh 1000000     # Quake, 1M-instruction prefix
bash verif/m7/win95/run-win95-cosim.sh          # Win95 boot prefix

cd rtl && verilator --lint-only -sv -Wall -Wno-UNUSED -f ventium.f   # lint
```

The instruction catalog at <https://al-255.github.io/ventium/> is built from
`docs/sphinx/` and deployed by `.github/workflows/docs.yml` on every push.

## Standard benchmarks

The classic CPU benchmark suite — **coremark, whetstone, stream, dhrystone,
linpack**, and a kernel set (**sieve, matmul-int, matmul-fp, crc32, nqueens**),
all prebuilt as static linux-user i386 ELFs in `ventium-refs/` — runs on the RTL
two ways, both graded against QEMU `-cpu pentium`:

- **Per-instruction lock-step** (the rigorous net, `verif/bench/run-deep-sweep.sh`):
  every retired instruction's full architectural + x87 state is compared vs the
  QEMU gdbstub golden, deep (tens of millions of instructions per config) and
  parallel, with zstd-compressed goldens streamed through `compare_stream.py`
  (O(1) disk + memory). **18/18 configs are bit-exact (EQUIVALENT).**
- **Free-run to completion** (`--emulate-syscalls`, `verif/bench/run-freerun.sh`):
  the testbench emulates `int 0x80` directly, so the RTL runs a whole program at
  full Verilator speed, graded by its output vs QEMU-native. **coremark** runs its
  full **1.45-billion-instruction** workload and prints *"Correct operation
  validated"* with the canonical CRCs.

Realistic **P5 (U+V dual-issue) IPC** per workload, from the same cycle model the
`make verify` bands hold the RTL to (P5 ceiling = 2.0):

| workload  | IPC  |   | workload   | IPC  |
|-----------|------|---|------------|------|
| nqueens   | 1.23 |   | linpack    | 0.69 |
| sieve     | 1.22 |   | matmul-fp  | 0.63 |
| crc32     | 0.98 |   | stream     | 0.50 |
| dhrystone | 0.87 |   | matmul-int | 0.46 |
| coremark  | 0.81 |   | whetstone  | 0.43 |

Integer-loop kernels approach IPC ~1.2; x87/transcendental and memory-bound code
sit lower (multi-cycle `imul`/`FSIN`, U-pipe-only FP, branch mispredicts).

**Quake** (the TyrQuake P5 build) also free-runs on the RTL: it boots fully (pak
load, palette, renderer) and renders its console frame via the software rasteriser.
At the FPGA target of **66 MHz** the cycle model estimates **~15 FPS** at 320×200
(cycles-per-frame), in line with a real Pentium-66. Getting all this clean cost
**three fixes**: a CET `endbr32` / multi-byte-NOP decode gap (a real RTL miss,
regression-tested by `t_endbr`) and two QEMU-golden producer-fidelity bugs
(`clock_gettime64` capture width, the i386 `recvfrom` syscall number).

## FPGA synthesis (KV260)

The core + FPU are fully synthesizable. Below is the **real Vivado placement** of
the `core` (out-of-context) on the KV260's **XCK26** (Zynq UltraScale+ ZU5EV,
`xck26-sfvc784-2LV-c`), with every placed leaf cell colored by its RTL module —
you can see the physical clusters (I-cache, FP datapath, branch predictor, the
iterative FP engines, the core spine, …). This is the **u_icache-rebalanced
floorplan** (a Pblock that spreads the byte-window decode logic across the upper
die), which **places MET at 22 ns (46.5 MHz, 0 failing endpoints)**.

![Ventium core placed on the KV260, colored by RTL module](docs/fpga-device-view.png)

The byte-window decode muxes (`u_icache`, the `-flatten_hierarchy rebuilt` instance
that absorbs the spine's 12×32:1 alignment fabric) are the level-5 routing-congestion
hotspot. Forcing them to spread (left) vs the default concentration (below) cuts the
peak MUXF density **63–65 % → 52–57 %**:

![u_icache placement: baseline concentration vs rebalanced spread](docs/fpga-rebalance-compare.png)

**Best numbers so far** — OOC `core`, `+VTM_NO_DPI`, all configurations **bit-exact
vs QEMU** (75/75 functional + the cycle micro-gates green):

| Resource | Used | Available | Util |
|---|---:|---:|---:|
| **CLB LUTs** | **90,083** | 117,120 | **76.9 %** ✅ fits |
| &nbsp;&nbsp;LUT as logic | 87,011 | 117,120 | 74.3 % |
| &nbsp;&nbsp;LUT as memory (the 8 KB icache) | 3,072 | 57,600 | 5.3 % |
| CLB Registers | 28,864 | 234,240 | 12.3 % |
| CARRY8 | 2,054 | 14,640 | 14.0 % |
| DSP48E2 | 31 | 1,248 | 2.5 % |
| Block RAM | 0 | 144 | 0 % |

- **Area: 518 % → 76.9 % LUTs (≈6.7× reduction).** The as-is single-cycle
  combinational Pentium datapath was 5.2× too big for the device; **iterative
  FDIV / FSQRT / integer-DIV / FBSTP / FBLD engines**, **LUTRAM caches**, and
  **FP-datapath consolidation** brought it comfortably under the XCK26.
- **Fmax: synth ≈ 64.1 MHz** (worst-path *logic* ~6.8 ns), **place MET ≈ 46.5 MHz**
  at 22 ns (AltSpreadLogic_high, 0 failing endpoints). The **66 MHz** target is **not
  met out-of-context**, and a rigorous Vivado strategy sweep — ~10 untried directives
  (`-muxf_remap`, AlternateRoutability, AltSpreadLogic, the canned congestion strategies)
  at a meetable clock with a full route, [`fpga/TIMING_PROBLEMS.md`](fpga/TIMING_PROBLEMS.md)
  P0-9 — confirms **no synth/place/route directive closes it**: `-muxf_remap` *regresses*
  to 35 MHz, and the device-filling design does **not route legally** at the ~46 MHz the
  placer estimates (the router gives up with thousands of congestion overlaps). The
  honest OOC **routable** Fmax is ≈ **35–42 MHz**. The binding constraint is **routing
  congestion** from the single-cycle x86 byte-window decoder (12×32:1 muxes over 256-bit
  cache lines), dense whether mapped to MUXF or LUT — an architectural property, not a
  tooling choice. The real levers are **RTL** (pipeline the decode window, the class of
  the validated `+VEN_IC_BRAM` fetch pipeline) or a lower-utilization device. Synth
  journey: 3.6 → 14.6 → 37.5 → 46 → 58 → 59.5 → 64.1 MHz.
- **Floorplan (the device view above):** a **u_icache-rebalance Pblock** that forces
  the byte-window decode logic to spread across the upper die cuts the peak MUXF
  congestion **63–65 % → 52–57 %** and **places MET at 22 ns (46.5 MHz)** — but the
  routing remains congestion-limited (the router thrashes), confirming floorplanning
  alone cannot break the wall. The genuine fix is the in-progress **decode-stage
  pipeline** (`+VEN_DEC_PIPE`, [`fpga/DEC_PIPE_DESIGN.md`](fpga/DEC_PIPE_DESIGN.md)):
  a decoupled prefetch→D1→D2 byte queue that moves the 12×32:1 alignment muxes off the
  combinational critical cone — the one RTL lever with a real shot at 66 MHz.
- A **2-stage FP execute pipeline** (`+VEN_FP_PIPE`) and a **BTB-update pipeline**
  (`+VEN_BTB_PIPE`, independently removable) move FP and the branch predictor off
  the critical path while keeping **both FP cycle bands and the branch-mispredict
  bands bit-identical** (they fit inside the modeled latency windows).

Reproduce: `vivado -mode batch -source fpga/scripts/device_view.tcl` →
`python3 fpga/scripts/render_device_view.py …`. Full timing backlog +
methodology in [`fpga/TIMING_PROBLEMS.md`](fpga/TIMING_PROBLEMS.md).

## Status

The planned roadmap is **complete** — M0–M6, the M2S.0–.6 system-mode track + the
M2S.4b hardware task switch, M5B + its M5B-int integration, the M6B system errata,
and the R1/R2 RTL refactors. **M7** (macro-workload lock-step — Quake + Win95)
landed, and **M8** (the self-contained SoC) is in progress. See
[`PROGRESS.md`](PROGRESS.md) and [`PROGRESS_Jun04.md`](PROGRESS_Jun04.md) for the
full, dated detail.
