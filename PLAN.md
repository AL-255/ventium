# Ventium — Pentium (P5/P54C) Microarchitecture Reconstruction Plan & Architecture

Ventium is a synthesizable SystemVerilog reconstruction of the non-MMX Intel Pentium (**P5/P54C**, Family 5) microarchitecture, verified differentially against a pinned **QEMU** Pentium reference model (`ventium-refs/`) under **Verilator** and deployed as a full PC/AT Zynq UltraScale+ SoC on the **RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`, AMD Vivado **2025.2**).

This document records the enduring architectural specification, reference map, verification methodology, implemented hardware reality, and milestone history. For current hardware qualification results, build recipes, and active open work, see:

- **[README.md](README.md)** — Overview, floorplans, and verified physical benchmarks (`c0e3fe43`)
- **[HOW_TO_RUN_FPGA.md](HOW_TO_RUN_FPGA.md)** — Public `main` Vivado build, board deployment, MMCM DRP clocking, and acceptance gates
- **[TODO.md](TODO.md)** — Verified baseline status and open experimental work on `experimental/uv-fast-ipc-apr`

---

## 1. Goal, Scope & Branch Boundary

**Goal.** Reconstruct the non-MMX Pentium P5/P54C microarchitecture—dual-issue in-order U+V integer execution, pipelined 80-bit x87 FPU with parallel `FXCH` renaming and polynomial transcendentals, 256-entry 4-way branch target prediction, split 8 KiB L1 instruction and banked data caches, 4-way set-associative I/D TLBs with hardware page walking, and full IA-32 real/protected/V86/SMM system architecture—capable of booting unmodified commercial 1990s operating systems and games on physical FPGA silicon.

**What "high fidelity" means.** Per `ventium-refs/REF.md`: Intel never published the Pentium RTL, microcode ROM listings, or internal validation suite. Gate-for-gate silicon equivalence is not achievable from public documentation; instead, Ventium is structured around five explicit verification layers:

1. **ISA-correct** IA-32 + 80-bit x87 architectural execution (lockstep state match vs. pinned QEMU + Berkeley SoftFloat).
2. **Bus- and system-visible** Pentium protocol, segmentation, paging, exception restartability, and PC/AT SoC integration.
3. **Cycle-compatible** U/V dual-issue integer pairing, AGI/prefix hazards, and L1 hit/miss behavior.
4. **Cycle-compatible** pipelined x87 execution and branch prediction.
5. **Stepping-specific behavior & errata** (radix-4 SRT `FDIV` Erratum 23 model, `F00F` lockup, strict P5 `#UD` boundary).

See [`docs/isa-coverage.md`](docs/isa-coverage.md), [`docs/modeled-by-effect.md`](docs/modeled-by-effect.md), and [`docs/unsupported-isa.md`](docs/unsupported-isa.md) for exact instruction and modeling boundaries.

**Target stepping.** **P54C, non-MMX, single processor, split 8 KiB L1 I$/D$ (no internal L2), no FRC.** P55C/MMX, P6 `CMOVcc`/`FCMOVcc`/`FCOMI`, APIC MP, and external 82496/82497 L2 chipsets are explicit non-goals and raise `#UD` where required by Family-5 ISA rules.

**Branch boundary & current gameplay baseline:**
- **`main` (`v0.2.0-c0e3fe43`, commit `64e567a6`)** publishes the hash-pinned 193-file / 161-define hardware source closure for board-qualified image **`c0e3fe43`**, which closes post-route STA at **`40.264133 MHz`** (`WNS = +0.164 ns`, `WHS = +0.010 ns`) and passes all three physical standard-suite gates at `40.000 MHz` with **`0.515778001` total U+V gameplay IPC** (`0.397847833` primary/U-only IPC; counters include `REP`-element retirement) across interior DOS Quake `demo1` cycles **`28,696,827,616–32,989,404,795`** (`8.0 FPS`, `969` frames / `121.2 s`).
- **`experimental/uv-fast-ipc-apr`** retains ongoing core, cache, FPU, verification, and APR experiments; post-freeze working RTL on `experimental/uv-fast-ipc-apr` is **unmeasured** on physical gameplay until separately re-qualified on the board.

---

## 2. Target P54C Specification vs. Implemented Hardware Reality

All architectural targets derive from `ventium-refs/` (Pentium Developer's Manual Vols. 1 & 3, Alpert & Avnon *IEEE Micro* 1993, Intel AP-500 / AP-526, and Agner Fog's P5 tables). Below is how each P54C subsystem is realized in the board-qualified Ventium RTL (`c0e3fe43`, 161 defines):

| Subsystem | P54C Architectural Target | Implemented Hardware Reality (`rtl/`, `fp_shared/`, `fpga/`) |
| --- | --- | --- |
| **Front End & Branch Prediction** | Split **8 KiB 2-way L1 I-Cache** (32 B lines), **256-entry 4-way BTB** with 2-bit saturating counters, variable-length decode into `D1`/`D2`. | `icache.sv` (8 KiB, 2-way, 32 B lines, 8&times;RAMB36 data + LUTRAM tags, snoop-coherent, replicated `pf_fill_addr_rep[0..3]` fanout), **32-entry 4-way I-TLB** (`VEN_ITLB_ASSOC_4WAY`) + resident front-end page filter, dual-ported **256-entry 4-way BTB** (simultaneous fetch lookup + retire update) with **4-entry RAS**, predecode length table, and dual U+V decoders (`decode.sv`, `decode_stages.sv`). |
| **Superscalar U+V Integer Core** | 5-stage in-order pipeline (`PF` &rarr; `D1` &rarr; `D2` &rarr; `EX` &rarr; `WB`), hardwired AP-500 U/V pairing, dual AGUs, 1-cycle AGI interlock, bypass network, microsequencer. | `core.sv` + `u_pipe.sv` + `v_pipe.sv` + `issue_uv.sv` (`cycle_mode = 1'b1`): AP-500 U/V pairing, 32-bit multi-port GPR file (`regfile.sv`) with hidden segment/descriptor caches, dual AGUs (`ven_p54_dual_agu.sv`), 1-cycle protected-mode flat/relocated/bounded load-store fast-path (`S_PIPE`: `MOV`, `ALU`, `PUSH`, `POP`, `LEA`, `MOVZX`, `MOVSX`), pipelined `REP STOS` cacheable store streaming (`VEN_REP_STOS_STREAM`), iterative hardware radix-2 divider (`ven_idiv.sv`), and full microsequencer/fragment engine (`core_*.svh`) for split-page accesses, task switches, V86, SMM, and precise x86 faults. |
| **x87 Floating-Point Unit** | 8-stage pipelined 80-bit x87 FPU, parallel `FXCH` stack renaming, Safe Instruction Recognition (SIR), radix-4 SRT div, polynomial transcendentals (`<1 ulp`). | `fp_shared/` (`ven_fp_top.sv`, `ven_fp_state.sv`, `ven_fp_alu.sv`, `ven_fp_trans.sv`, `fpu_srt_div.sv`, `ven_bcd.sv`): IEEE-754 80-bit `ST(0)..ST(7)` stack with **zero-cycle `FXCH` rename queue** (`ven_fp_fxch_queue.sv`), pipelined add/sub/compare, 38-DSP shared wide multiplier &amp; polynomial transcendental engine (`FSIN`, `FCOS`, `FSINCOS`, `FPTAN`, `FPATAN`, `F2XM1`, `FYL2X`, `FPREM`/`FPREM1`), radix-4 SRT divider/sqrt (with optional Erratum 23 PLA mode), and x87 exception/environment tracking. |
| **L1 Data Cache & MMU** | **8 KiB 2-way L1 D-Cache** (32 B lines, **8 interleaved 32-bit banks** for dual U+V access), dual-ported D-TLB, hardware 4 KiB / 4 MiB page walker. | `ven_l1d.sv` (8 KiB, 2-way, 32 B lines, 8-way interleaved banks + `ven_p54_hit_return.sv` dual-port read hit return, byte-exact UC MMIO/I/O), **64-entry 4-way D-TLB** (`tlb_assoc.sv`) + front-end D-TLB slice (`ven_fe_dtlb.sv`), hardware 2-level 4 KiB / 4 MiB PSE page walker, probe-before-write split-page fragment engine, and 64-bit AXI4 master (`ven_axi_master.sv`). |
| **Bus & RK-XCZU15EG-F PC/AT SoC** | 64-bit burst external bus (`biu_p5.sv`) in standalone verification; full PC/AT chipset + DDR4 memory system on FPGA. | Standalone P5 64-bit BIU (`rtl/bus/biu_p5.sv`) for protocol/SVA verification; in SoC mode, `ven_ao486_shim.sv` + `ven_axi2avalon.sv` integrate Ventium into the MiSTer PC/AT chipset (`8259A` PIC, `8254` PIT, `8237` DMA, `MC146818` RTC, PS/2 kbd/mouse + HW injection mailboxes, IDE, FDD, VGA + 128-RAMB36 capture, SB16/OPL3) over `ven_ddram_axi_posted.sv` (**16-slot posted write queue + CAM RAW bypass + external drain barrier**) to ZynqMP `S_AXI_HP0_FPD` (`0x6000_0000`) with runtime XAPP888 MMCM DRP clocking (`ven_pll_ctrl.sv`). |

---

## 3. Reference Map (`ventium-refs/`)

On `experimental/uv-fast-ipc-apr`, consult `ventium-refs/00-index/INDEX.md` first, then inspect the cited specification pages:

| Topic | Primary Reference(s) in `ventium-refs/` |
| --- | --- |
| Pipeline stages, U/V pairing, BTB, x87 stages | Pentium Developer's Manual **Vol. 1 Ch. 2**; Alpert &amp; Avnon (*IEEE Micro* 1993, `02-pipeline-internals/`) |
| Latency, throughput &amp; pairability rules | Intel **AP-500** (`241799`), **AP-526** (`242816`), **Agner Fog** P5 tables (`03-optimization-timing/`) |
| IA-32 &amp; x87 ISA, paging, TSS, V86, SMM, `CPUID` | Pentium Developer's Manual **Vol. 3**; IA-32 SDM 1997 (`243190`/`91`/`92`) |
| External 64-bit P5 pin &amp; bus protocol | Pentium Processor Datasheet (`241997-010`, `01-intel-canonical/`) |
| Silicon errata (`FDIV`, `F00F`, SMM/BTB) | Pentium Specification Updates (`242480-022`/`-041`, `01-intel-canonical/`) |
| Circuit sanity checks, FPU constant ROM | Ken Shirriff reverse-engineering notes &amp; die photos (`05-die-photos-reverse-eng/`) |
| Functional &amp; cycle golden oracle | `07-p5-emulation-harness/` (pinned `qemu-i386` / `qemu-system-i386 -cpu pentium` + `p5model`) |
| Decoder cross-check oracles | Intel XED / Capstone / Bochs / QEMU (`06-emulators-decoders/`) |

---

## 4. Verification Philosophy & Gates

1. **Differential Oracle Authority (`verif/`):** Instruction-by-instruction architectural lockstep against the pinned QEMU Pentium oracle in `ventium-refs/` is the primary correctness authority (`make verify`, `make verify-sys`, `make verify-all`). Traces are emitted exclusively through `verif/diff/tracefmt.py` (see [`docs/trace-format.md`](docs/trace-format.md)). Comparison masks are never weakened, and regressions are never converted into expected-failure pins.
2. **SoftFloat / MPFR x87 Verification (`fp_shared/tb/`):** Extended-precision 80-bit arithmetic, rounding modes, flags (`C0..C3`), `FXCH` queue interactions, SRT division, and polynomial transcendentals are validated against Berkeley SoftFloat and MPFR reference vectors rather than host `double`.
3. **Subsystem, Lint & SVA Gates:** Dedicated testbenches cover the 8-bank L1D/I-cache/TLB hierarchy (`make l1`), 64-bit P5 bus protocol and SystemVerilog assertions (`make bus bus-sva`), and strict Verilator structural lint (`make lint`, keeping `IMPLICIT`, `PINMISSING`, `UNDRIVEN`, `MULTIDRIVEN`, `LATCH`, and `UNOPTFLAT` fatal).
4. **Full-PC Simulation (`ao486-sim/`) & Physical FPGA Standard Suite (`fpga/`):** Full-system boot testing runs in Verilator (`ao486-sim/`) and culminates on the physical **RK-XCZU15EG-F** board in mandatory `U/V + fast-pipe` mode (`cycle_mode=1`) across all three standard acceptance gates: (1) both standard CoreMark CRC seeds, (2) cold Windows 95 OSR2 GUI boot + interactive PS/2 mouse/keyboard + clean shutdown, and (3) cold DOS Quake `timedemo demo1` + interior gameplay IPC measurement.

---

## 5. Repository Layout

```text
ventium/
  AGENTS.md                      Repository invariants, branch rules & acceptance contract
  README.md                      Project overview, c0e3fe43 physical benchmarks & CLB floorplans
  HOW_TO_RUN_FPGA.md             Vivado 2025.2 build, RK-XCZU15EG-F bring-up, DRP clock & suite guide
  PLAN.md                        Architectural specification, verification strategy & milestone history
  TODO.md                        Current status & active experimental work items
  rtl_ven_core.f, rtl_ven_soc.f  Ordered SystemVerilog synthesis filelists (never globbed)
  rtl/                           Synthesizable P5/P54C core, L1 caches, 4-way TLBs, BIU & legacy FPU
  fp_shared/                     Shared pipelined 80-bit x87 FPU, FXCH rename, SRT & transcendentals
  ao486-sim/                     Full-PC Verilator harness & CPU-to-platform shim (ven_ao486_shim)
  3rd-party/                     MiSTer PC/AT chipset, VGA, IDE, DMA, PS/2 & SB16/OPL3 peripheral RTL
  verif/                         QEMU lockstep differential suites, system tests, L1/bus/SVA & unit TBs
  fpga/                          RK-XCZU15EG-F Vivado wrappers, posted-DDR/PLL RTL & board-tools
  docs/                          Block specs, interface/trace docs, release notes & physical maps
  tools/                         Vivado systemd scope guards, ROM bootstrap & opcode-map verifier
  ventium-refs/                  Private submodule (experimental branch): specs & pinned QEMU oracle
```

---

## 6. Phased Milestones & Completion History

Every foundational milestone from initial bootstrap through full 40 MHz STA-closed physical FPGA qualification has been completed:

| Milestone | Scope & Gate | Status |
| --- | --- | --- |
| **M0 — Bootstrap** | Repository skeleton, QEMU golden trace plugin, `.vtrace` comparator (`tracefmt.py`), Verilator TB shell, `isa_verify.py`. | **COMPLETED** |
| **M1 — Single-Issue Core** | Variable-length x86 decode, prefixes, ModR/M+SIB, GPR file, ALU/flags, initial microsequencer, XED/QEMU diff gate. | **COMPLETED** |
| **M2 — User-Mode Integer ISA** | Complete P5 user-mode integer ISA (`MUL`/`IMUL`/`DIV`/`IDIV`, bit ops, shifts/rotates, `MOVZX`/`MOVSX`, `REP` strings, partial regs, `LOCK`). | **COMPLETED** |
| **M2S — System Architecture** | Protected mode, segmentation, 4 KiB / 4 MiB PSE paging, 4-way I/D TLBs + hardware walker, precise exceptions, 32-bit TSS task switches, V86, SMM/`RSM`, `DR0–DR7`, `CPUID`, `RDTSC`. | **COMPLETED** |
| **M3 — 80-Bit x87 FPU** | Extended-precision `ST(0)..ST(7)` stack, tag/status/control words, SoftFloat-verified `FADD`/`FMUL`/`FDIV`/`FSQRT`, `FSAVE`/`FRSTOR`/`FLDENV`. | **COMPLETED** |
| **M4 — U/V Dual-Issue & BTB** | Hardwired AP-500 U+V pairing (`issue_uv.sv`), dual AGUs, AGI stalls, bypass network, 256-entry 4-way BTB + 4-entry RAS, cycle-band validation. | **COMPLETED** |
| **M5 — Caches & Shared Pipelined FPU** | Split 8 KiB 2-way L1 I-Cache + 8-bank dual-port-read 8 KiB L1 D-Cache (`ven_l1d`), 64-bit AXI4 master, hardware radix-2 `ven_idiv`, pipelined `fp_shared/` with `FXCH` rename queue. | **COMPLETED** |
| **M5B — 64-Bit P5 Bus Protocol** | Pin-level P5 burst/snoop/pipelined `NA#`/`LOCK#`/`BOFF#` bus unit (`biu_p5.sv`) + SVA protocol suite (`make bus bus-sva`). | **COMPLETED** |
| **M6 — Stepping Errata & Hygiene** | Configurable Pentium `FDIV` Erratum 23 PLA model, `F00F` lockup behavior, strict `#UD` on post-P54C (`MMX`/`CMOVcc`/`FCMOVcc`/`RDPMC`) opcodes. | **COMPLETED** |
| **M7–M10 — Full-PC SoC Integration** | `ven_ao486_shim` + MiSTer PC/AT integration, split-page probe-before-write fragment engine, protected-mode `S_PIPE` fast load/store/relocated pipeline, 16-slot posted DDR4 bridge with CAM RAW bypass &amp; external drain barrier. | **COMPLETED** |
| **M11 — Hardware Polynomial Transcendentals** | Synthesizable 38-DSP shared wide multiplier &amp; polynomial engine (`ven_fp_trans.sv`) for `FSIN`, `FCOS`, `FSINCOS`, `FPTAN`, `FPATAN`, `F2XM1`, `FYL2X`, `FYL2XP1`, `FPREM`/`FPREM1`. | **COMPLETED** |
| **M12 — Physical FPGA Qualification (`c0e3fe43`)** | **RK-XCZU15EG-F** Vivado 2025.2 **40.264 MHz post-route STA sign-off** (`WNS +0.164 ns`, `WHS +0.010 ns`, `0` `>=85%` congestion hotspots); physical pass on CoreMark (both seeds), cold **Windows 95 OSR2 GUI** + PS/2 mouse/kbd + shutdown, and cold **DOS Quake `demo1`** (`8.0 FPS`, **`0.515778001` total U+V IPC**); runtime DRP overclocking up to `58.824 MHz` (Win95+Quake) / `62.500 MHz` (Quake); self-contained `main` source release (`v0.2.0-c0e3fe43`). | **COMPLETED (`main`)** |

---

## 7. Ongoing Scope & Explicit Non-Goals

- **Active experimental work (`experimental/uv-fast-ipc-apr`):** Branch reconciliation with `main` (`c0e3fe43`), unified 161-define differential regression targets, further P54C IPC/FPU/cache fidelity (precision-gated single-precision `FDIV`, VIPT I-cache tags, broader U/V pairing, write-back L1D), 8237 ISA DMA bridging for Sound Blaster 16 / Floppy, and deeper pipeline retiming beyond 40 MHz STA. Tracked in **[TODO.md](TODO.md)**.
- **Permanent v1 Non-Goals:** P55C/MMX (`0F` SIMD), P6 instructions (`CMOVcc`, `FCMOVcc`, `FCOMI`, `RDPMC`), dual-socket SMP / APIC MP, Functional Redundancy Checking (FRC), external 82496/82497 L2 cache controller pins, and JTAG boundary-scan (`BSCANE2`) equivalence.
