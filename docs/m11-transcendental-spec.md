# M11 — x87 Transcendentals (FSIN/FCOS/FPATAN/F2XM1/FYL2X…), the implementation spec

Task #11. Decode boundary today: `core.sv:2024` (`default: d_unknown` in the D9 reg
escape) → `S_HALT` (the deferred-op loud HALT, machine-checked by `tx_deferred_halt`).
Grounded by the `x87-transcendental-recon` workflow against the pinned oracle
`qemu-i386 8.2.2` source (`…/target/i386/tcg/fpu_helper.c`).

## 0. The decisive split (this is the whole story)

The 8 ops divide by **how QEMU 8.2 computes them**, which dictates how we can verify a
hardware-faithful implementation:

| Op | Opcode | QEMU 8.2 path | Verifiable as |
|----|--------|---------------|----------------|
| **F2XM1**   | D9 F0 | **softfloat** — 65-entry ROM + deg-7 Horner + 128/192-bit reduce | **bit-exact vs QEMU** |
| **FYL2X**   | D9 F1 | **softfloat** — `fyl2x_common`, deg-9 odd Horner + 128/192/256-bit long-div | **bit-exact vs QEMU** |
| **FYL2XP1** | D9 F9 | **softfloat** — shares `fyl2x_common` | **bit-exact vs QEMU** |
| **FPATAN**  | D9 F3 | **softfloat** — deg-6 odd Horner + 9-entry ROM + two 192-bit long-divs | **bit-exact vs QEMU** |
| **FSIN**    | D9 FE | floatx80→double→**host glibc `sin()`**→floatx80 | ulp-tolerance only |
| **FCOS**    | D9 FF | host `cos()` | ulp-tolerance only |
| **FSINCOS** | D9 FB | host `sin()`+`cos()` | ulp-tolerance only |
| **FPTAN**   | D9 F2 | host `tan()` (value); pushes `+1.0` | ulp-tolerance only (value) |

**Group B (softfloat)** — QEMU's algorithm is a deterministic floatx80 polynomial with
every constant in source. Transcribing it bit-exactly is **both hardware-faithful AND
bit-exact vs the oracle** — no verification compromise. **Quake's only transcendental is
FPATAN** (2 `d9 f3` sites in glibc `atan`/`atan2`, per-frame), so Group B alone unblocks F4.

**Group A (host-libm)** — the result bits come from the *build host's* glibc, not an
algorithm in QEMU at all, and aren't even stable across glibc versions. **No synthesizable
core can match them bit-for-bit.** A hardware-faithful CORDIC here is genuinely correct
silicon behavior but is structurally un-gradeable bit-exact against this oracle.

## 1. Verification strategy

- **Group B:** the existing `make verify` x87 path, unchanged — `gen_trace --x87` golden vs
  the `+VEN_TRANSCENDENTAL` RTL, `compare.py --mode func` exact st0..st7 (it grades 80-bit
  hex with zero tolerance, `compare.py:236-238`). One test program per op (`tx_f2xm1`,
  `tx_fpatan`, `tx_fyl2x`, `tx_fyl2xp1`), each `x87:true`. This is the real bit-exact gate.
- **Group A (the owner's "hardware-faithful for all" directive):** implement the real P5
  algorithm (CORDIC/poly + the reduction constants) and verify with a **two-part oracle**,
  NOT by injecting QEMU's answer (that would fabricate a pass — rejected, per
  `m7-lockstep-spec.md:103,108`):
  1. **RTL bit-exact vs a C reference model** of the same algorithm (the executable spec) —
     this is the "the RTL correctly implements the engine" gate, same rigor as everything.
  2. The **C model independently validated** within the documented P5 error envelope
     (FSIN/FCOS ≤ ~1 ulp, with the known near-π degradation) vs a high-precision reference
     (mpmath / `long double`) — so the spec is *correct*, not just self-consistent.
  3. In `make verify`, these four ops compare vs QEMU under a **documented ulp-tolerance
     band** (a new tolerant st0 path in `compare.py`, scoped to the transcendental records),
     labelled "tolerance-verified, not bit-exact — QEMU uses host libm." Honest + explicit.
- Fix the doc drift in `m3-fpu-spec.md:50-54`: it defers the *whole family* as "QEMU's own
  approximation ≠ real Pentium." That's wrong for Group B (exact, not approximate) and
  understated for Group A (the blocker is host-libm, not silicon mismatch).

## 2. Implementation order (high-value + low-risk first)

All on the proven iterative-engine pattern (the FDIV/FSQRT `S_FP_BUSY` + `ven_bcd_to_fp`
`start/busy/done/result` handshake). New gate `+VEN_TRANSCENDENTAL`; new FSM state
`S_TRSC_BUSY` (enum next to `S_FP_BUSY`/`S_BCD_BUSY`); decode arms for `D9 F0/F1/F3/F9`
replace the `d_unknown` at `core.sv:2024` (the four libm opcodes `F2/FB/FE/FF` keep
HALTing under the gate until Group A lands). Commit ports (we_top/we_push/we_pop/we_fstat)
already exist on `fpu_top.sv` — no new port.

- **Phase 0 — primitives + ROMs** (shared, in `fpu_x87_pkg.sv`): transcribe QEMU's
  `mul128By64To192`, `mul128To256`, `add/sub128/192`, `shift128RightJamming`,
  `estimateDiv128To64`, and a **widened `normalizeRoundAndPackFloatx80`** (accept 192/256-bit
  jammed significands — today `fx_round_pack` is ≤128-bit). Transcribe the constant ROMs
  verbatim from QEMU (`f2xm1_table[65]`+coeffs, `fyl2x_coeff`+`log2_e_sig`,
  `fpatan_coeff`+`fpatan_table[9]`+`pi_*`, `ln2_sig`). Unit-test the primitives vs QEMU values.
- **Phase 1 — F2XM1** (`rtl/fpu/fpu_f2xm1.sv`): simplest softfloat op, no long division —
  the datapath validator. Domain [-1,1]→INVALID/dNaN. Bit-exact gate `tx_f2xm1`.
- **Phase 2 — FPATAN** (`rtl/fpu/fpu_fpatan.sv`): **the Quake-critical op.** Two 192-bit
  long-divs, 9-entry atan ROM, deg-6 odd Horner, quadrant adjust (±π/±π2/±π4/±3π4), the
  `floatx80_div` exact-division special case, final `fpop`. Gate `tx_fpatan`.
- **Phase 3 — FYL2X + FYL2XP1** (`fpu_fyl2x_common.sv` once): deg-9 odd Horner +
  `estimateDiv128To64` long-div; FYL2X (replace+pop, DBZ@0, INVALID@x<0), FYL2XP1 (replace,
  INVALID outside the AMD range) wrap it. Gates `tx_fyl2x`, `tx_fyl2xp1`.
- **Phase 4 — Group A** (`fpu_fsin.sv` etc.): CORDIC/poly + the P5 reduction; the C model +
  the `compare.py` ulp-tolerance harness (§1). FSINCOS/FPTAN reuse FSIN/FCOS; the C2
  out-of-range flag (|x|>2^63) IS reproducible and graded exactly even here.

## 3. CHOSEN TARGET — accuracy-faithful to the real Pentium silicon

(Owner decision, 2026-06-09.) §0–§2 above describe the *QEMU-faithful* axis (bit-exact
vs the pinned oracle). The actual goal is to match the **real Pentium P5/P54C silicon**.
Grounded by the `pentium-fpu-silicon-recon` workflow reading Ken Shirriff's die-level
constant-ROM extraction (righto.com/2025/01/pentium-floating-point-ROM.html) + Intel docs.

### 3.1 Feasibility verdict (honest)
**Bit-exact-to-silicon is NOT achievable from public data:** (a) the transcendental
*microcode* ROM is undumped (the op-sequence/rounding that fixes the low bits is unknown);
(b) the Remez polynomial *coefficient* words are unpublished (only anchor constants +
"differs <1% from 1/k!" qualitative notes); (c) the 68th-significand "flag bit" semantics
are unknown. AND there is **no bit-exact oracle** for the silicon target anyway (QEMU ≠ the
Pentium; for FSIN/FCOS QEMU uses host glibc, not even self-consistent across hosts).
**Achievable = accuracy-faithful:** the documented algorithm + silicon reduction constants,
correct to the P5's ~1 ulp envelope AND reproducing its characteristic errors (the famous
near-π FSIN catastrophe). "Behaviorally the Pentium," not provably its last ulp.

### 3.2 The silicon algorithm (Remez polynomials, NOT CORDIC — that was the 8087/387)
ROM = 304 × 86-bit (18-bit exp incl. sign, bias `0x0FFFF`; 68-bit sig = flag + integer +
66 frac = 67 sig bits). Verified anchor: ROM π sig `0x6487ed5110b4611a6` (67-bit) ==
QEMU π `0xc90fdaa22168c234` (64-bit) ≪3 + `110`.
- **FSIN/FCOS/FSINCOS/FPTAN**: reduce by ROM π/π2/π4 (the 67-bit π → the near-π error),
  then finer table reduction with sin/cos(n/64) via `sin(a+b)=sin a cos b+cos a sin b`;
  4-term & 6-term Remez Horner on `[-π/4,π/4]`-ish. FPTAN = sin/cos.
- **FPATAN**: `atan(x)=atan((x−c)/(1+xc))+atan(c)`, c=nearest n/32 from the 32-entry
  atan(n/32) table (entry156 = π/4), reduce to `[-1/64,1/64]`, odd-power Remez Horner.
- **F2XM1**: reduce by ROM `2^(n/128)−1` (64-entry, irregular spacing) to `[-1/128,1/128]`,
  e^x series (1/n!, entries 33–49) scaled by ln2, subtract 1 separately; 6-/11-term.
- **FYL2X/FYL2XP1**: x→[1,2], divide by `1+n/64`, add split-precision log₂(1+n/64)
  (40-bit "top" entries 206–237 + 67-bit "bottom" 238–269 = 107-bit), atanh odd Horner,
  fuse-multiply by y at extended precision.

### 3.3 The build is from-first-principles (constants computable)
The silicon reduction constants ARE π, ln2, log₂e/log₂10, arctan(n/32), log₂(1+n/64),
2^(n/128)−1, sin/cos(n/64) **rounded to the ROM's 67-bit precision** — generate them at
high precision and round (the recon's extracted hex is the cross-check; π already matches).
Only the polynomial coefficients are reconstructed (minimax/Remez fit to the documented
degree + reduced interval). The near-π behavior emerges naturally from reducing an 80-bit
arg with the 67-bit π.

### 3.4 DUAL-MODE — silicon is the ship target, QEMU mode keeps the bit-exact gate
(Owner decision, 2026-06-09: "make this an option, so we can still run verification.")
The engine is built ONCE and parameterized by `+VEN_TRSC_SILICON`; both modes share the
algorithm STRUCTURE (the reduction identities + the Horner form) and differ only in the
constant/coefficient ROM and the internal precision/rounding:

| | **QEMU mode** (default under `+VEN_TRANSCENDENTAL`) | **Silicon mode** (`+VEN_TRSC_SILICON`) |
|---|---|---|
| Group B (F2XM1/FYL2X/FYL2XP1/FPATAN) | reproduce QEMU's exact softfloat (its coeffs + wide-int datapath + round-pack) → **BIT-EXACT vs the pinned oracle** | the P5 constants (67-bit) + reconstructed Remez coeffs + 67-bit internal → the silicon behavior |
| Group A (FSIN/FCOS/FSINCOS/FPTAN) | un-gradeable (QEMU=host glibc) → stay `d_unknown`/HALT, OR run + tolerance-checked vs the model | the P5 reduction (67-bit π → near-π signature) + Remez |
| Oracle | `make verify` x87 diff vs QEMU, **exact st0** (the project's bedrock gate) | the C model (§ below) + ulp-tolerance |

So **`make verify` stays a real bit-exact gate** (run the QEMU-mode build: F2XM1/FYL2X/
FYL2XP1/FPATAN diff-clean vs QEMU, incl. Quake's FPATAN), and the shipped silicon-mode
build delivers the authentic P5 behavior, verified against the model below.

### 3.4a Verification (silicon mode — no silicon oracle → a C reference model is the spec)
1. **`tools/p5xtrans/p5xtrans.c`** = the executable silicon spec: the algorithm + the
   67-bit-rounded constants + the reconstructed coefficients, in `long double`/wider with
   explicit guards, rounded to floatx80. **Validated** to ~1 ulp vs mpmath/`long double`
   truth AND it must reproduce the known error signatures (near-π, the Intel-documented
   worst cases). This is the authority for the silicon mode.
2. **RTL (silicon mode) bit-exact vs `p5xtrans`** — the "RTL faithfully implements the
   spec" gate, full project rigor (the model, not QEMU, is the oracle for these ops).
3. `make verify` x87 diff vs QEMU in silicon mode uses a **documented ulp-tolerance band**
   (FPATAN/F2XM1 agree with the silicon to ~1 ulp; FSIN/FCOS diverge near π exactly as the
   silicon does vs glibc). Honest (computes + validates), NOT injecting QEMU's answer.

### 3.5 Implementation order
C model first (it's the spec, validatable in software), then the matching RTL engine + a
`tx_*` bit-exact-vs-model gate, per op: **F2XM1** (validator) → **FPATAN** (Quake's only
transcendental; silicon ≈ QEMU within ~1 ulp so it's also near-bit-exact there) →
**FYL2X/FYL2XP1** → **FSIN/FCOS/FSINCOS/FPTAN** (the near-π signature). All behind
`+VEN_TRANSCENDENTAL` / `S_TRSC_BUSY`; default build + every existing gate byte-identical;
`tx_deferred_halt` keeps pinning whatever is still `d_unknown`.
