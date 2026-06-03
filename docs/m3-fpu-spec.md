# M3 — x87 FPU spec

M3 (PLAN §7) adds the **x87 floating-point unit** to the core and verifies it
**diff-clean vs QEMU** on the x87 architectural state. Builds on M1/M2 (the
integer core is unchanged). This is the hardest functional milestone: 80-bit
extended precision, the FP stack, and the status/control/tag words.

## Verified prerequisites (already in place)

- **Golden x87 trace works.** `gen_trace.py --x87` now reads the i387 g-packet
  block correctly (the tail-anchor fix, commit c39905b): `fld1` → st0 =
  `0x3fff8000000000000000` (1.0), `fldpi` → π, `fstat` TOP field tracks the
  stack. Validated.
- **QEMU user-mode reports `fop`/`fiseg`/`fioff`/`foseg`/`fooff` = 0** (no FP
  instruction/data-pointer tracking in linux-user). So the RTL just reports 0 for
  those — no fip/fdp bookkeeping needed.
- **`fctrl` resets to `0x037f`** (RC=00 round-nearest, PC=11 64-bit precision,
  all six exception masks set). The core initializes the control word to this.
- The comparator compares the full x87 set when both traces declare `x87:true`
  (`tracefmt.func_compare_keys(x87=True)` = st0..st7, fctrl, fstat, ftag, fop,
  fioff, fooff, fiseg, foseg). Since the pointer fields are 0, the live state to
  match is **st0..st7, fctrl, fstat, ftag**.

## Scope (tiers — be honest about what's gated vs deferred)

The arithmetic must match **QEMU's softfloat `floatx80`** bit-exactly. That is
very achievable for data movement and for normal-operand arithmetic with the
default control word; it is genuinely hard for some edge/rounding corners and
effectively impossible (against QEMU) for transcendentals. So M3 is tiered:

- **Tier 1 — HARD GATE (must pass, bit-exact):** the x87 register stack model
  (8×80-bit + TOP), status word (TOP, condition codes C0–C3, the C1 stack-fault
  bit), control word (FLDCW/FNSTCW), tag word (match QEMU's reported convention —
  see below), and these ops:
  - Load/store/move: `FLD`/`FST`/`FSTP` (m32/m64/m80 + `st(i)`), `FILD`/`FIST`/
    `FISTP` (m16/m32/m64), `FXCH`, `FFREE`, `FINCSTP`/`FDECSTP`, `FNOP`.
  - Constants: `FLDZ FLD1 FLDPI FLDL2E FLDL2T FLDLG2 FLDLN2`.
  - Sign/abs: `FABS`, `FCHS`.
  - Compare (set C0/C2/C3): `FCOM`/`FCOMP`/`FCOMPP`, `FUCOM`/`FUCOMP`/`FUCOMPP`,
    `FTST`, `FXAM`, `FICOM`/`FICOMP`.
  - Status/control: `FNSTSW ax`/`m16`, `FNSTCW`/`FLDCW`, `FNINIT`/`FINIT`,
    `FNCLEX`/`FCLEX`, `FWAIT`.
- **Tier 2 — TARGET (gated on normal operands, default control word):** core
  arithmetic `FADD/FSUB/FSUBR/FMUL/FDIV/FDIVR` (+ `p`/`ip` and memory/int forms
  `FIADD…`), `FSQRT`. Round-to-nearest-even, 64-bit precision. Must be bit-exact
  vs QEMU on **normal, non-exceptional** operands (the gated corpus uses these).
- **Tier 3 — best-effort, documented:** non-default rounding (RC) and precision
  (PC) control, signed zeros / infinities / NaN propagation, denormals, `FPREM`/
  `FPREM1`, `FRNDINT`, `FSCALE`, `FXTRACT`. Cover what passes; document divergences.
- **DEFERRED — loud HALT, never fake:**
  - **Transcendentals** `FSIN FCOS FSINCOS FPTAN FPATAN F2XM1 FYL2X FYL2XP1`:
    QEMU computes these with its own approximation; matching it bit-exact ≠
    matching a real Pentium, so deferred to a later milestone with an
    ulp-tolerance oracle (REF.md §8). HALT for now.
  - BCD `FBLD`/`FBSTP`; environment/state `FSAVE/FRSTOR/FLDENV/FNSTENV` (28/108-
    byte memory images) — deferred; HALT.
  - x87 numeric exceptions actually *raised* (unmasked → #MF): the corpus keeps
    exceptions masked (default cw) and avoids faulting operands.

## RTL ↔ TB x87 trace hook (infrastructure to build)

`rtl-interface.md` §2 reserved a second DPI import for FP. Define and wire it:

```systemverilog
import "DPI-C" context function void vtm_retire_x87(
    input longint unsigned n,          // SAME retire seq as the matching vtm_retire
    input int      unsigned fctrl, input int unsigned fstat, input int unsigned ftag,
    input longint unsigned st0_lo, input shortint unsigned st0_hi,  // 80-bit = 64 lo + 16 hi
    ... st1..st7 ...);
```
- The core calls `vtm_retire` (integer state, unchanged) **and**, on the same
  retirement, `vtm_retire_x87` with the post-commit x87 state. The TB
  (`dpi_retire.cpp`) buffers both and emits ONE func record carrying the x87
  fields; the RTL trace header must then declare `x87:true`. Use the 80-bit
  canonical `floatx80` layout (sign|exp in [79:64], mantissa in [63:0]) — the
  SAME encoding `gen_trace` now produces, so hex strings compare directly.
- Pass each 80-bit st reg as a 64-bit mantissa + 16-bit sign/exp pair (or a packed
  vector) — pick one and keep TB+pkg consistent.
- fop/fiseg/fioff/foseg/fooff: emit 0 (matches QEMU user-mode).

**ftag convention:** QEMU's user-mode gdbstub reported `ftag = 0x0000` in probes.
The infra/harness phase MUST confirm QEMU's exact ftag behavior across cases
(empty/full stack, FFREE, after pops) and the RTL reproduces *whatever QEMU
reports* — do not assume the architectural 2-bit-per-reg tag if QEMU abridges it.

## Verification (the M3 gate)

Same multi-program differential mechanism; goldens generated with `--x87`, RTL
trace declares `x87:true`, `compare.py --mode func` compares the x87 fields too.
Integer programs (no x87) keep `x87:false` and are unaffected.
```
gen_trace.py --x87 --elf <p>.elf --out build/m3/<p>_qemu.vtrace --max-insn <N>
tb_ventium --image <p>.flat ... --out build/m3/<p>_rtl.vtrace   # header x87:true
compare.py --mode func build/m3/<p>_qemu.vtrace build/m3/<p>_rtl.vtrace   # exit 0
```
**Gate (`make m3` / `verif/run-m3.sh`):** all Tier-1 + Tier-2 x87 programs are
func-diff-clean (exit 0), AND the M0/M1/M2 integer suites stay green (`make m2`
exit 0). Tier-3 coverage and every deferred/HALT item are listed honestly in
PROGRESS. Anything unimplemented HALTs the core — never silently mis-executes.
```
