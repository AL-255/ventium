# M11 — x87 Transcendentals (F2XM1/FPATAN/FYL2X/FYL2XP1/FSIN/FCOS/FSINCOS/FPTAN)

**STATUS: COMPLETE (#11, 2026-06-09).** All 8 x87 transcendentals are implemented
as iterative microcoded engines, gated behind `+VEN_TRANSCENDENTAL`. The default
build is byte-identical (they still decode to `d_unknown` → HALT there, so
`make verify` stays 77/77 GREEN). Quake's only transcendental is FPATAN, so this
unblocks F4.

| Op | Opcode | Engine | Graded |
|----|--------|--------|--------|
| **F2XM1**   | D9 F0 | `rtl/fpu/fpu_f2xm1.sv`  | bit-exact vs qemu-i386 (187 × 4 RC) |
| **FYL2X**   | D9 F1 | `rtl/fpu/fpu_fyl2x.sv`  | bit-exact vs qemu-i386 (316 × 4 RC) |
| **FPTAN**   | D9 F2 | `rtl/fpu/fpu_fsincos.sv`| bit-exact vs the shared-poly model |
| **FPATAN**  | D9 F3 | `rtl/fpu/fpu_fpatan.sv` | bit-exact vs qemu-i386 (296 × 4 RC) |
| **FYL2XP1** | D9 F9 | `rtl/fpu/fpu_fyl2x.sv`  | bit-exact vs qemu-i386 (324 × 4 RC) |
| **FSINCOS** | D9 FB | `rtl/fpu/fpu_fsincos.sv`| bit-exact vs the shared-poly model |
| **FSIN**    | D9 FE | `rtl/fpu/fpu_fsincos.sv`| bit-exact vs the shared-poly model |
| **FCOS**    | D9 FF | `rtl/fpu/fpu_fsincos.sv`| bit-exact vs the shared-poly model |

## 0. The decisive split (how QEMU computes them → how we grade them)

QEMU 8.2's `target/i386/tcg/fpu_helper.c` (the pinned oracle) computes the 8 ops two ways:

- **Group B — F2XM1 / FYL2X / FYL2XP1 / FPATAN — softfloat.** A deterministic floatx80
  polynomial with every constant in source. Transcribing it bit-exactly is **both
  hardware-faithful AND bit-exact vs the oracle.**
- **Group A — FSIN / FCOS / FSINCOS / FPTAN — host glibc.** QEMU does
  `floatx80 → double → host glibc sin()/cos() → floatx80`. The result bits come from the
  *build host's* glibc at **double precision** (~53 bits), not an algorithm in QEMU and not
  stable across hosts. **No core can match them bit-for-bit, and they are LESS accurate than
  the real Pentium's extended-precision FSIN.** So qemu is not the oracle for Group A.

## 1. Verification — two postures, both fully rigorous

- **Group B — bit-exact vs qemu-i386.** For each op `tools/p5xtrans/qref.c` holds a verbatim
  port of qemu's softfloat helper (table + Horner via host `long double` = floatx80 RNE;
  the 128/192/256-bit reconstruction via `__int128`). `qref_validate.py` proves the C
  reference reproduces the *actual* pinned `qemu-i386` bit-for-bit by tracing an asm sweep
  (`gen_trace --x87`, all four rounding modes via `fldcw`). The RTL engine is then a verbatim
  transcription of that reference, graded bit-exact against it (`verif/trsc/run-*-gate.sh`,
  all 4 RC) and through the core vs the qemu gdbstub golden (`run-*-core-gate.sh`,
  `compare.py --mode func`, exact st0..st7/fctrl/fstat/ftag).
- **Group A — bit-exact vs a shared-polynomial silicon model.** Since qemu can't be the
  oracle, the model is: octant reduction (3-part Cody-Waite π/2 from the 128-bit qemu π/2)
  + Taylor sin/cos, evaluated **entirely in floatx80 ops** (host `long double` == the RTL's
  `fx_mul`/`fx_add`), so the RTL is graded **bit-exact vs the model** (`run-fsincos-gate.sh`,
  4008 vec). The MODEL's accuracy is graded **~1.8 ulp vs `__float128` quad truth**
  (`qref --validate-trig`). The in-core gate (`run-fsincos-core-gate.sh`) shows core==model
  bit-exact AND core-vs-qemu ≈ 1000 ulp — i.e. the silicon model is demonstrably **more
  faithful than qemu's double precision**. FPTAN = sin/cos (`fx_div`); the C2 out-of-range
  flag (|x| ≥ 2^63 = MAXTAN) is reproducible and graded exactly.

## 2. Engine / core integration

All engines follow the proven iterative pattern (`start / busy / done-strobe / result`,
mirroring `ven_bcd_to_fp`). Decode arms for `D9 F0/F1/F2/F3/F9/FB/FE/FF` replace the
`d_unknown` at `core.sv:2024` under `+VEN_TRANSCENDENTAL`; a new FSM state `S_TRSC_BUSY`
busy-waits for `done` and retires. Commit (via the existing `fp_we_*` driver):

- **F2XM1, FSIN, FCOS** — in-place ST0 (`we_top`). FSIN/FCOS also drive the C2 flag.
- **FPATAN, FYL2X, FYL2XP1** — write ST1 then pop (`we_sti(1)` + `we_pop`, like FDIVP ST1,ST0).
- **FSINCOS** — ST0←sin, push cos (`we_top(sin)` + `we_push(cos)` → {ST0=cos, ST1=sin}).
- **FPTAN** — ST0←tan, push +1.0 (`we_top(fx_div(sin,cos))` + `we_push(+1.0)`).

The softfloat wide-int kit (`shift128*`, `mul128_192/256`, `estimateDiv128To64`,
`normalizeRoundAndPackFloatx80`) is factored into `rtl/fpu/fpu_trsc_wideint.svh`. The
constant ROMs (`fpu_f2xm1_rom.svh`, `fpu_fpatan_rom.svh`, `fpu_fyl2x_rom.svh`,
`fpu_fsincos_rom.svh`) are generated from the same qemu source / `qref --rom-*`.

## 3. Silicon fidelity — what "faithful" means here

The goal was the real Pentium P5/P54C silicon, grounded in Ken Shirriff's die-level
constant-ROM extraction (righto.com/2025/01/pentium-floating-point-ROM.html) + Intel docs.
Two facts shaped the build:

- **Bit-exact-to-silicon is not achievable from public data** (undumped transcendental
  microcode, unpublished Remez coefficient words, unknown 68-bit "flag-bit" semantics, and
  no bit-exact silicon oracle). What IS achievable is **accuracy-faithful**: the documented
  algorithm + silicon reduction structure, ~1 ulp, reproducing the characteristic behaviors.
- **For Group B, qemu's softfloat algorithm IS itself the accuracy-faithful silicon one**
  (80-bit table + Horner + reconstruct, ~0.5 ulp, no catastrophic-reduction divergence). So
  a single datapath serves both the bit-exact-vs-qemu gate and silicon fidelity — there was
  no need for a separate silicon-mode datapath, and the engines' `SILICON` parameter is
  reserved/inert. `tools/p5xtrans/p5xtrans.c` remains the independent silicon-accuracy
  cross-check (it agrees with qemu/qref to < 1 ulp).
- **For Group A, the shared-poly model IS the silicon-accuracy target** (§1). The famous
  near-π FSIN degradation is an accuracy-faithful gap: the model uses a finite (128-bit)
  π/2, so it degrades for |x| beyond ~2^24 like real silicon, but the *exact* near-π bit
  pattern needs the undumped reduction precision and is documented, not reproduced.

## 4. #6 — FP scoreboard latency (closed as by-design)

The cycle-model FP scoreboard (`fp_ready_cyc`/`fp_occ`, `core.sv:805`) stays on the **fixed
P5 latencies** (the `p5trace.c` oracle constants), NOT the iterative engines' real `done`.
The cycle (M4/M5) arm and the functional engine arm are runtime-exclusive; an engine's
done-latency is an implementation artifact (SRT step count, ~20-clk microcode) tuned for
bit-exactness/area, not real-P5 timing, so feeding it back would diverge from the cycle
oracle. Rationale documented at the scoreboard. (Owner-confirmed.)
