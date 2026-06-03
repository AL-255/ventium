# Ventium — P5 (Pentium) microarchitecture replica in Verilog

A high-fidelity RTL reconstruction of the original Intel Pentium (P5/P54C)
microarchitecture, written in synthesizable SystemVerilog, simulated with
**Verilator**, and verified differentially against **QEMU**.

This document is the durable plan. Day-to-day status lives in
[`PROGRESS.md`](PROGRESS.md).

---

## 1. Goal and honest scope

**Goal.** Reproduce the *microarchitecture* of the original Pentium — not just an
IA-32 functional model, but the actual in-order dual-pipe (U/V) structure, the
5-stage integer pipeline, the 8-stage x87 FPU pipeline, the 256-entry 4-way BTB,
the split 8 KB L1 caches, and the 64-bit external bus — so that both the
*architectural results* and the *cycle behavior* match a real P54C as closely as
public sources allow.

**What "high fidelity" can and cannot mean.** Per
[`ventium-refs/REF.md`](ventium-refs/REF.md) §intro: Intel never published the
Pentium RTL, microcode listings, internal scoreboard logic, or its validation
database. True gate-for-gate RTL accuracy is therefore **not achievable from
public sources**. What *is* achievable, and what we target, is:

1. **ISA-correct** IA-32 + x87 execution (bit-exact architectural state).
2. **Bus-visible** Pentium-compatible pin/protocol behavior.
3. **Cycle-compatible** for L1-resident integer code.
4. **Cycle-compatible** for x87 and branch-heavy code.
5. *(stretch)* **Stepping-specific errata** behavior (FDIV, F00F, …).

These are exactly the five success layers REF.md recommends. We treat them as
hard milestone gates (see §7).

**Target stepping.** Per REF.md "Practical recommendation": **P54C, non-MMX,
single processor, L1-only, no FRC.** MMX (P55C), dual-processing/APIC-MP, and FRC
are explicit non-goals for v1 (see §9). This matches the existing golden-model
harness in `ventium-refs/07-p5-emulation-harness`, which is also P54C/non-MMX.

---

## 2. Target microarchitecture (the spec we implement)

Concrete parameters, all sourced from the reference library. Citations point to
`ventium-refs/00-index/` abstracted indexes (which in turn cite PDF pages).

### Integer core
- **Pipeline:** in-order, dual-issue, 5 stages: **PF → D1 → D2 → EX → WB**
  (Alpert & Avnon IEEE Micro 1993, p.2; Dev. Manual ch.2).
- **Two pipes:** **U** (full-feature) and **V** (restricted). One or two
  instructions issued per clock.
- **Pairing rules** (Dev. Manual ch.2; AP-500 241799; Agner Fog):
  - **UV** (either pipe): `mov`, `add/sub/and/or/xor/cmp`, `inc/dec`, `lea`,
    `push/pop` reg, `test reg,reg`/`test eax,imm`, `nop`.
  - **U-only pairable:** `adc`, `sbb`, shift/rotate by immediate.
  - **V-only pairable:** simple near branches (`jmp`, `jcc`, `call`).
  - **Not pairable / microcoded:** `mul`, `imul`, `div`, `idiv`, `neg`, `not`,
    `xchg`, `movzx/movsx`, `setcc`, `bt*`, `shld/shrd`, `ret`, string ops,
    all x87 arithmetic (pairs only with `fxch`).
  - Pairing forbidden on RAW/WAW on GP regs (ESP & flags excluded — stack-engine
    / cmp+jcc special cases), on displacement+immediate, and prefixed ops are
    U-only.
- **Execution units:** 2× integer ALU, barrel shifter, multiplier, radix-?
  divider, flags logic, full bypass/interlock network.
- **AGI:** 1-cycle stall when an address base/index reg was written in the
  immediately preceding clock.

### Branch prediction
- **BTB:** 256 entries, **4-way** associative (64 sets), 2-bit/4-state saturating
  counters, accessed in **D1** (Alpert & Avnon p.3, Fig. 6).
- **Policy:** BTB-miss ⇒ predict not-taken; first-taken allocates and
  mispredicts. Mispredict resolved at WB.
- **Penalty:** 3 cycles (branch in U-pipe) / 4 cycles (V-pipe); taken
  uncond/`call` = 3. Correctly predicted = 0 extra.

### x87 FPU
- **Pipeline:** 8 stages **PF/D1/D2/E/X1/X2/WF/ER** (Alpert & Avnon p.6, Fig. 8).
- **Datapath blocks:** FIRC, FEXP, FMUL, FADD, FDIV, FRND (Fig. 9).
- **Stack file** (80-bit), tag word, status/control words, exception logic.
- **Safe Instruction Recognition (SIR)** for stall avoidance, X1-stage detection,
  6 exception classes (p.7).
- **Parallel FXCH** in the V pipe (p.8) — implies stack renaming/bypass.
- **Representative latencies (core clocks):** `fadd/fsub` lat 3 / tput 1;
  `fmul` lat 3 / tput 2; `fdiv` 19/33/39 (precision-dependent); `fsqrt` 70;
  transcendentals ~120. (Agner Fog P5 table.)
- **Transcendentals:** table-driven polynomial approximation, <1 ulp (p.8) —
  requires the FPU constant ROM.

### Memory subsystem (L1-only for v1)
- **I-cache:** 8 KB, 2-way, 32-byte line (128 sets).
- **D-cache:** 8 KB, 2-way, 32-byte line, **8-way interleaved banks**, write-back
  **MESI**, LRU, dual-ported TLB/tags (Alpert & Avnon p.5, Fig. 7). U-pipe wins
  bank conflicts.
- **Misaligned data access:** +3 cycles.
- **TLBs:** separate I/D TLBs; paging + segmentation address generation.
- **Write buffers**, store→load behavior.
- *(v2 / non-goal for first cut)* external 82496/82497 L2 chipset (Dev. Manual
  Vol. 2).

### System / bus
- **External bus:** 64-bit data, burst fills, locked cycles, pipelined cycles via
  `NA#`, writebacks, snoops (`AHOLD/EADS#`, `HIT#/HITM#`), `KEN#`, `CACHE#`,
  `HOLD/HLDA`, `BOFF#`, reset/INIT/BIST. (Datasheet 241997-010.)
- **Architectural state:** segmentation, paging, task switching,
  interrupts/exceptions with fault priority + restartability, debug registers,
  SMM/`RSM`, CPUID, MSRs, test registers, RDTSC + 2× 40-bit perf counters.
- **Microcode/control ROM** for complex/serializing instructions.

(Full block list: REF.md §9. Block decomposition and module map: §6 below.)

---

## 3. Reference map — which document answers which question

Read the cheap abstracted index first
([`ventium-refs/00-index/INDEX.md`](ventium-refs/00-index/INDEX.md)), then open
the cited PDF page. Key mappings:

| Need | Primary source(s) |
|---|---|
| Pipeline stages, pairing, branch pred, FPU stages | Pentium Dev. Manual **ch.2**; Alpert & Avnon (`02-pipeline-internals/`) |
| Exact U/V issue pseudocode + "simple" definition | Alpert & Avnon p.3 (Fig. 5) |
| Latency / throughput / pairability numbers | AP-500 241799, AP-526 242816, **Agner Fog** tables + µarch guide (`03-optimization-timing/`) |
| ISA semantics, flags, exceptions, paging, x87, SMM, CPUID | Dev. Manual **Vol. 3**; IA-32 SDM 1997 (243190/91/92) |
| Pin/bus protocol | Datasheet 241997-010 (`01-intel-canonical/`) |
| Errata (define "accurate" behavior) | Spec updates 242480-022/-041, MMX 243185 (`01-intel-canonical/`) |
| L2 cache chipset (v2) | Dev. Manual **Vol. 2** |
| Circuit/floorplan sanity checks, FPU adder, ROM | Ken Shirriff articles, die photos (`05-die-photos-reverse-eng/`) |
| Functional + cycle **golden reference** | `07-p5-emulation-harness/` (QEMU `-cpu pentium` + `p5model` plugin) |
| Decoder cross-check oracles | XED / Capstone / Bochs / QEMU (`06-emulators-decoders/`) |

---

## 4. Verification strategy — Verilator + QEMU

The core methodology is **differential testing** (a.k.a. co-simulation): run the
same program through a trusted oracle and through our RTL, and compare. This is
exactly the stack REF.md §8 prescribes (Verilator + differential harness against
QEMU/Bochs/XED + golden trace format).

### 4.1 Golden trace from QEMU
- Build the plugin-enabled `qemu-i386 -cpu pentium` the harness already produces
  (`07-p5-emulation-harness/scripts/10-build-emulator.sh`). It #UDs on any
  non-P5 opcode, so it is a faithful **P5 ISA** oracle.
- Write a new **trace plugin** (sibling to `plugin/p5model.c`) that, for every
  retired instruction, emits the **golden trace record** (REF.md §8):
  `EIP, EFLAGS, GP regs, segment selectors + hidden descriptor state,
  CRx/DRx/TRx/MSRs, x87 stack/tag/status/control, exception/fault metadata,
  and (where modeled) a bus-cycle trace`.
- For **cycle** checks, the existing `p5model` plugin already produces a per-run
  cycle estimate and instruction mix mined from the same documents — it is our
  **cycle golden reference** for success-layers 3–4.

### 4.2 RTL trace from Verilator
- Verilate the SystemVerilog core into a C++ model. A C++ **testbench** loads the
  same flat memory image (the test's `.text`/`.data`), drives reset/clock, and on
  each instruction retirement emits a trace record in the **same format**.
- A simple memory + minimal "bus functional model" stands in for DRAM in v1
  (L1-only, no external L2).

### 4.3 The differential comparator
- A Python/C++ tool diffs the two trace streams record-by-record and reports the
  first divergence (instruction index, field, expected vs. got). Two modes:
  - **Functional mode** — compare architectural state only (layers 1–2). This is
    the primary correctness gate.
  - **Cycle mode** — compare retire cycle / CPI against the `p5model` estimate
    within a tolerance band (layers 3–4). Cycle equality is *approximate* by
    construction (the cycle oracle is itself an estimate; see harness README
    "What it does NOT model").

### 4.4 Static + dynamic ISA hygiene
- Reuse `tools/isa_verify.py` (capstone) to guarantee every test binary is pure
  P5 ISA before it ever runs — keeps us from "passing" on instructions the real
  chip would #UD.

### 4.5 Test corpus (built up over milestones; REF.md §7)
1. **Decoder exhaustive** — all prefixes, ModR/M, SIB, disp/imm sizes, illegal
   encodings, LOCK legality, seg/operand/addr-size overrides, `0F` map, x87
   escapes. Cross-checked against XED/Capstone.
2. **ISA architectural** — flags, exception/fault priority + restartability, task
   switches, segmentation, paging, V86, IOPL, debug regs, TSS, `IRET`, gates,
   `CMPXCHG8B`, `RDTSC`, `CPUID`.
3. **x87** — 80-bit precision, stack faults, tag word, masking, denormals/NaN/Inf,
   rounding, `FSAVE/FRSTOR`, `FLDENV`, `FWAIT`. FP oracle: SoftFloat/MPFR (REF.md
   §8) — *not* host `double`.
4. **Microarchitecture timing** — pairing, prefix stalls, AGI, load-use,
   store→load, branch prediction, BTB aliasing, SMC, cache-line/page splits,
   non-cacheable memory, TLB miss, L1 disabled. (The harness `microbench.c` /
   `55-validate-model.sh` kernels are the seed set.)
5. **Bus/protocol** — burst fills, writebacks, `LOCK#`, INTA, `HOLD/HLDA`,
   `BOFF#`, snoops, `KEN#/CACHE#`, pipelined `NA#`, reset/INIT/BIST.
6. **Software compatibility** — the harness benchmark set (Dhrystone, Whetstone,
   LINPACK, CoreMark, STREAM, sieve/matmul/crc32/nqueens), later DOS/GCC-torture
   style workloads.

### 4.6 Tooling (REF.md §8)
- **Verilator** primary sim; **Icarus** for a second opinion / non-Verilator
  constructs.
- **cocotb** for constrained-random instruction & bus tests.
- **SymbiYosys / Yosys / SVA** for local formal checks (decoder properties,
  pairing-legality invariants, cache coherence lemmas).

---

## 5. Repository layout (to be created)

```
ventium/
  PLAN.md                  ← this file
  PROGRESS.md              ← living status / changelog
  ventium-refs/            ← submodule: docs + QEMU golden-model harness (read-only)
  rtl/                     ← synthesizable SystemVerilog
    core/                  ← fetch, decode, pairing, U/V issue, EX, WB
    fpu/                   ← x87 8-stage pipeline + datapath + constant ROM
    mem/                   ← I$, D$ (banked, MESI), TLBs, write buffers
    bus/                   ← 64-bit bus interface unit, snoop logic
    ucode/                 ← microcode/control ROM + assembler
    sys/                   ← segmentation, paging, interrupts, SMM, MSRs, debug
    ventium_top.sv         ← top level
  verif/
    tb/                    ← Verilator C++ testbench + bus functional model
    qemu-plugins/          ← golden-trace plugin (sibling to p5model.c)
    diff/                  ← trace comparator (functional + cycle modes)
    tests/                 ← decoder / ISA / x87 / µarch / bus / compat corpora
    cocotb/                ← constrained-random
    formal/               ← SymbiYosys/SVA
  tools/                   ← build scripts, trace format defs, helpers
  docs/                    ← design notes, block specs, decisions log
  Makefile / build system
```

---

## 6. RTL block decomposition (REF.md §9)

Each block gets a design note in `docs/` before RTL, and a unit testbench.

1. **Front end:** prefetch buffers, I-cache, BTB + 4-state predictor, branch
   address calc.
2. **Decode:** variable-length x86 length decoder, prefix machine, ModR/M+SIB,
   D1/D2 split, **pairability checker** (the U/V issue algorithm).
3. **Integer execution:** U & V issue/control, 2× ALU, shifter, mul, div, flags,
   bypass/interlock, AGI detection.
4. **Address generation:** AGUs, segmentation, paging, I/D TLBs.
5. **Data memory:** D-cache (8 banks, MESI, LRU, dual port), write buffers,
   store/load ordering, misalignment/split handling.
6. **x87 FPU:** stack file, tag word, 80-bit add/mul/div/sqrt, transcendental ROM
   + polynomial engine, status/control/exception logic, SIR, FXCH bypass.
7. **Microcode engine:** control ROM + sequencer for complex/serializing ops.
8. **Interrupt/exception pipeline:** fault priority, restart logic, INT/INTA.
9. **System state:** debug registers/breakpoints/single-step, SMM + SMRAM
   save/restore + `RSM`, CPUID/MSRs/test registers, RDTSC + 2 perf counters.
10. **Bus interface unit:** 64-bit bus FSM, burst, locked, pipelined, snoops,
    reset/INIT/BIST.

---

## 7. Phased milestones (gated by REF.md success layers)

Each milestone ends with a **green differential gate** before the next begins.
Effort estimates are coarse; this is a long project.

- **M0 — Bootstrap (infrastructure).**
  Repo skeleton; build the QEMU golden trace plugin; define the golden-trace
  record format; stand up the Verilator testbench shell + bus functional model +
  trace comparator; wire `isa_verify.py`. *Gate:* an empty/NOP RTL core boots
  reset and the comparator runs end-to-end on a trivial trace.

- **M1 — Decoder + functional integer single-issue (→ layer 1, partial).**
  Length decode, prefix machine, ModR/M/SIB, integer ALU subset, register file,
  flags. Single-issue (U only) first. Microcode engine stub.
  *Gate:* decoder matches XED/Capstone on the exhaustive corpus; integer ISA
  tests pass differentially vs. QEMU (arch state).

- **M2 — User-mode integer ISA completeness (→ layer 1, user-mode integer).**
  *Re-scoped from the original "full integer + system" M2 for verifiability:* our
  differential oracle is QEMU **user-mode** (linux-user gdbstub), which runs flat
  and cannot exercise paging/segmentation/SMM. So M2 completes the **user-visible
  integer ISA** that QEMU user-mode *can* validate: shifts/rotates, mul/imul/
  div/idiv, movzx/movsx, setcc, neg/not, xchg, bt/bts/btr/btc, bsf/bsr, shld/shrd,
  string ops (movs/stos/lods/scas/cmps + REP/REPNE), loop/loopcc/jcxz, push/pop
  variants, pushf/popf/lahf/sahf, cdq/cwde/cbw, and 8/16-bit operand forms with
  correct **partial-register** semantics + the operand-size/address-size/segment/
  LOCK **prefixes**. Functional I$/D$ memory already works (real caches = M5).
  `int 0x80` stays a halt (no Linux syscall emulation; test programs are self-
  contained). *Gate:* a broad generated integer-ISA corpus is diff-clean vs QEMU
  (EFLAGS undefined-bit masking per `tracefmt.EFLAGS_UNDEFINED`). Decoder-
  exhaustive-vs-XED remains ongoing.

- **M2S — System mode: segmentation, paging, TLBs, interrupts, SMM (→ layer 1
  complete + layer 2).** *Deferred from M2; needs a new oracle.* Stand up a
  **system-mode** golden path (`qemu-system-i386` + a system-state trace via
  gdbstub/QMP or a system TCG plugin) and a bare-metal test harness, then add
  segmentation, paging + TLBs, the interrupt/exception pipeline (fault priority +
  restartability), debug registers, SMM/`RSM`, CPUID/MSRs/test registers. *Gate:*
  system-architectural corpus + a boot-ish workload pass differentially. Sequence
  after M3/M4 if cycle work is higher priority.

- **M3 — x87 FPU (→ layer 1 with x87).**
  8-stage FPU, 80-bit datapath, transcendental ROM, exception/status logic.
  *Gate:* x87 corpus passes vs. SoftFloat/MPFR oracle and QEMU.

- **M4 — Dual-issue U/V + pairing + branch prediction (→ layer 3).**
  Turn on V pipe, full pairing checker, BTB + predictor, AGI, bypass.
  *Gate:* `55-validate-model.sh`-style microbenchmarks match the `p5model`
  cycle estimate (CPI, pairing %, mispredict %) within tolerance; harness
  benchmarks track the cycle golden reference.

- **M5 — Cache/bus timing + x87 cycle accuracy (→ layers 2 & 4).**
  Banked D-cache timing, write buffers, 64-bit bus FSM with burst/locked/
  pipelined/snoop cycles; FPU cycle behavior. *Gate:* bus/protocol corpus passes;
  cycle match extends to FP + branch-heavy code.

- **M6 — Errata & stepping fidelity (→ layer 5, stretch).**
  Model documented errata from spec updates (FDIV, F00F, SMM/BTB quirks, …) for a
  chosen stepping. *Gate:* targeted errata reproduction tests.

---

## 8. Risks and open questions

- **Cycle oracle is an estimate, not silicon.** The `p5model` plugin's
  cache-miss latency etc. are tunable assumptions (harness README). Cycle "match"
  is therefore band-limited; true cycle-exactness needs real-chip RDTSC/perf-
  counter traces (REF.md §4) which we don't yet have. *Mitigation:* treat layer
  3–4 gates as tolerance bands; flag any acquisition of real-chip traces as a
  fidelity upgrade.
- **Microcode is unpublished.** Complex-instruction cycle counts come from timing
  tables, not a ROM listing. We synthesize a behaviorally-equivalent microcode
  engine, not Intel's actual ROM.
- **Transcendental/FDIV bit-exactness.** x87 80-bit + table-driven polynomials
  must match to <1 ulp; the FDIV bug itself is an *erratum* to reproduce (M6),
  not a defect to fix.
- **Scope creep.** MMX, dual-proc/APIC-MP, FRC, L2 chipset are explicitly v2+.
- **Decoder completeness.** The x86 encoding space is large; exhaustive coverage
  is bounded by the corpus — log any sampling/truncation rather than implying
  full coverage.

## 9. Non-goals (v1)

P55C/**MMX**; dual-processing, APIC/IO-APIC MP, FRC; external **82496/82497 L2**
cache chipset; boundary-scan/JTAG pin-exact behavior; gate-level/standard-cell
equivalence to die photos (used for sanity only). Revisit after M5.
