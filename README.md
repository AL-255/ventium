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

- **reference:** <https://al-255.github.io/ventium/>
- **Reference library + golden model:** [`ventium-refs/`](ventium-refs/) submodule
  (Intel manuals, Alpert & Avnon, Agner Fog, datasheet, spec updates, and a
  working QEMU `-cpu pentium` functional + cycle golden harness).

## What's implemented

- **Integer core** — a 5-stage in-order **dual-issue (U/V)** pipeline
  (PF/D1/D2/EX/WB), AP-500 U/V pairing (including the ADC/SBB = PU carry-chain
  rule), the variable-length decoder, a **broad IA-32 integer ISA** (incl. the
  BCD/ASCII adjusts AAA/AAS/DAA/DAS/AAM/AAD) with **documented HALT gaps** — every
  unimplemented opcode HALTs loudly, never mis-executes; the coverage boundary is
  machine-listed in [`docs/isa-coverage.md`](docs/isa-coverage.md). Plus AGI
  interlock and a 256-entry / 4-way BTB with 2-bit predictors.
- **x87 FPU** — an 80-bit `floatx80` datapath with the stack / status / control /
  tag words; data movement + normal-operand arithmetic bit-exact vs QEMU softfloat.
  Transcendentals, BCD FP (`FBLD`/`FBSTP`), environment save/restore, and unmasked
  numeric exceptions are **deferred and HALT** (see `docs/m3-fpu-spec.md`).
- **Memory** — 8 KiB / 2-way / 32 B split L1 I/D caches (LRU), split 16-entry I/D
  TLBs, and the 2-level paging MMU (A/D bits, 4 KiB + 4 MiB pages). The L1 D-cache
  is a **timing model** (hit/miss latency only — no data array, MESI, or write
  buffers; load data returns via the memory model) and the TLB is a **correctness
  model** (16-entry direct-mapped, not the P54C-structured TLB); both are
  cycle/behaviour-faithful, not structural (`docs/cache-tlb-structural-spec.md`).
  The **64-bit P5 bus** (`biu_p5`) is a faithful pin-level **protocol** engine
  validated standalone (19 SVA + 76 checks); its integrated `bus_mode` is a
  **protocol exerciser** — single non-burst cycles, and the pins do not carry the
  data the core consumes (default-off; `docs/m5b-bus-spec.md`).
- **System mode** — cold reset → real mode → protected-mode segmentation →
  paging → IDT-delivered interrupts/exceptions + `IRET`, TSS + cross-privilege +
  the **hardware task switch**, **SMM / `RSM`**, **debug registers + `#DB`**, and
  **virtual-8086** mode.
- **Errata** — documented P5 silicon errata (FDIV, FIST, F00F, MOV-moffs, the V86
  `POPF`/`IRET` `#DB`) reproduced behind a default-off flag, self-checked against
  the Intel Specification Updates (never against QEMU, which computes correctly).
- **Macro-workload lock-step (M7)** — real programs run on the RTL in lock-step
  vs QEMU: **Quake** is bit-exact over **~1.1M instructions**, and a **Windows 95
  boot** is bit-exact to **213,859 instructions** (input-replay: QEMU is the golden
  + environment, the RTL is the checked CPU). This found + fixed **6 real ISA gaps**
  (`TEST r/m,imm` mem-form, `call gs:[]`, `LOCK CMPXCHG`, `IN`/`OUT`, `CPUID`, `INS`).
- **Self-contained SoC (M8, in progress)** — synthesizable PC-platform device
  models (8259 PIC, 8254 PIT, MC146818 RTC, 8042 keyboard / A20, port-92, ACPI PM
  timer, VGA register file, IDE/ATA disk), toward booting without QEMU as the
  platform. The
  `ventium_soc` integration wires the core (an external INTR/INTA pin driving the
  IDT-delivery FSM) to the **PIC + PIT** (M8.1, on-die IRQ0 — checkpoint-differential),
  to the **RTC + 8042 + port-92 + a combined A20 address mask** (M8.2 — a
  *full per-record* differential vs `qemu-system-i386` over every retired
  instruction, incl. the 1 MiB A20 wraparound), to the **VGA register file +
  ACPI PM timer** (M8.3 — a full per-record VGA differential: SEQ/GFX/DAC/ATTR/CRTC
  register masks, color/mono port aliasing, CRTC CR0-7 write-lock, IS1 dumb-retrace;
  the ACPI PM read is a documented host-clock oracle boundary), and to an **IDE/ATA
  disk** (M8.4 — a PIO primary-master controller: a full per-record differential of
  the reset signature, IDENTIFY, READ + WRITE SECTORS (single + multi-sector,
  byte-identical to a single-source disk image, with writes proved by read-back),
  and DIAGNOSTIC; `gen_disk.py` feeds the *same* image to QEMU's `-drive` and the
  RTL's `$readmemh`). A bus-master DMA engine, an OPL3/SoundBlaster card, and PCI
  follow.

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

## Status

The planned roadmap is **complete** — M0–M6, the M2S.0–.6 system-mode track + the
M2S.4b hardware task switch, M5B + its M5B-int integration, the M6B system errata,
and the R1/R2 RTL refactors. **M7** (macro-workload lock-step — Quake + Win95)
landed, and **M8** (the self-contained SoC) is in progress. See
[`PROGRESS.md`](PROGRESS.md) and [`PROGRESS_Jun04.md`](PROGRESS_Jun04.md) for the
full, dated detail.
