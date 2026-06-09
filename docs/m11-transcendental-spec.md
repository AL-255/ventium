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

## 3. Status

Design complete (this doc). Implementation: Phase 0 starting. Default build + every
existing gate stay byte-identical (all behind `+VEN_TRANSCENDENTAL`); the `tx_deferred_halt`
boundary keeps pinning whatever stays `d_unknown`.
