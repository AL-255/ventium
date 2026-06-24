// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/ven_fp_ps.c — FP_PS_ALL x87 op dispatcher backed by SoftFloat
// extF80 (Berkeley SoftFloat-3e, 8086-SSE specialization = x87-faithful floatx80).
//
// See ven_fp_ps.h for the seam contract. The fxop_e ordinals MUST match
// rtl/core/ventium_decode_pkg.sv (kept in sync below); the read/write index map +
// the stack-action codes MUST match rtl/soc/ven_soc_axil.sv (R_FPT_* window) and
// rtl/core/fpu_writeback.sv (the VEN_FP_PS_ALL generalized commit arm).
//
// STATUS / COMPLETION PLAN
// ------------------------
// DONE + smoke-gated (run-fp-ps-gate.sh): FADD/FSUB/FSUBR/FMUL/FDIV/FDIVR (ST0,ST(i) /
// ST(i),ST0 / mem-float / mem-int), FSQRT, FRNDINT, FSCALE, FCOM/FCOMP/FUCOM/FCOMPP/
// FUCOMPP/FTST/FICOM (condition codes), FXAM (classify) — all bit-exact via SoftFloat
// extF80, control-word RC honored. This is the set the make-verify FP corpus + Quake's
// rasterizer hit, so it is sufficient to bring the FP_PS_ALL area-relief bitstream up.
//
// TODO to reach FULL fidelity (tracked):
//  (1) Transcendentals (FPATAN/FYL2X/FYL2XP1/F2XM1/FSIN/FCOS/FSINCOS/FPTAN) + FPREM
//      currently use a libm double bridge (ven_fp_ps_transc) — adequate for Quake but
//      NOT 80-bit-exact. Replace with the qref.c extF80 transcendental kernels
//      (tools/p5xtrans, the QEMU-bit-exact ports already used by fpu_*.sv) for full
//      x87-faithful results. The dispatch + commit plumbing is already in place.
//  (2) Precision-control (PC=fctrl[9:8]): NOW HONORED via extF80_roundingPrecision
//      (pc_to_prec below) — the result is rounded to 24/53/64-bit significand per PC.
//      [Was previously unmodeled (always 64-bit extended) with a "benign for Quake"
//      note — that was WRONG: Quake runs PC=00 (24-bit single) and the extra mantissa
//      bits accumulated across the per-frame math into a wrong FIST loop bound (the
//      board-F5 divergence). This is the root-cause fix on the PS FP path.]
//  (3) FXAM empty-ST0: the trap window does not expose fptag[ftop], so an FXAM on an
//      empty register classifies as its numeric class, not "Empty 101". Expose the
//      tag bit (a spare DATA index) to close this rare edge.
//  (4) Denormal/UE/OE/exception-flag fidelity beyond IE/PE: SoftFloat raises the full
//      flag set; merge_excep() currently maps only IE+PE into fstat. Extend to DE/ZE/
//      OE/UE if a strict-flag differential gate is wired against QEMU.

#include "ven_fp_ps.h"
#include "ven_soc_regs.h"
#include <math.h>

// ---- SoftFloat extF80 -------------------------------------------------------
// The library is built -DSOFTFLOAT_FAST_INT64 (by-value extFloat80_t) -DLITTLEENDIAN=1
// with SPECIALIZE_TYPE=8086-SSE (x87 NaN/exception semantics). extFloat80_t is
// { uint64_t signif; uint16_t signExp; } — exactly our {mant64, sign|exp15} floatx80.
#define SOFTFLOAT_FAST_INT64 1
#include "softfloat.h"

// ---- fxop_e ordinals (mirror ventium_decode_pkg.sv EXACTLY; fptrap_op = 7'(q_fxop),
// the RAW fxop_e ordinal, is forwarded over R_FPT_STAT[7:1]). FX_NONE==0, then the enum
// continues in declaration order. These MUST match the RTL or every op mis-decodes. ----
enum {
  FX_NONE = 0,
  FX_FLD_M32 = 1, FX_FLD_M64, FX_FLD_M80, FX_FLD_STI,
  FX_FILD_M16, FX_FILD_M32, FX_FILD_M64,
  FX_FLDCONST,
  FX_FST_M32, FX_FST_M64, FX_FST_M80, FX_FST_STI,      // 9..12
  FX_FIST_M16, FX_FIST_M32, FX_FIST_M64,               // 13..15
  FX_FNSTCW, FX_FNSTSW_M, FX_FNSTSW_AX, FX_FLDCW,       // 16..19
  FX_FXCH, FX_FFREE, FX_FINCSTP, FX_FDECSTP, FX_FNOP, FX_FNINIT, FX_FNCLEX, FX_FWAIT,
  FX_FABS, FX_FCHS,                                     // 28..29
  FX_FCOM_M32, FX_FCOM_M64, FX_FCOM_STI, FX_FUCOM_STI,  // 30..33
  FX_FCOMPP, FX_FUCOMPP, FX_FTST, FX_FXAM,              // 34..37
  FX_FICOM_M16, FX_FICOM_M32,                           // 38..39
  FX_AR_ST0_STI, FX_AR_STI_ST0, FX_AR_M32, FX_AR_M64, FX_AR_I16, FX_AR_I32,  // 40..45
  FX_FSQRT,                                             // 46
  FX_FBLD, FX_FBSTP,                                    // 47..48
  FX_FNSTENV, FX_FLDENV, FX_FNSAVE, FX_FRSTOR,          // 49..52
  FX_F2XM1, FX_FPATAN, FX_FYL2X, FX_FYL2XP1, FX_FSIN, FX_FCOS, FX_FSINCOS, FX_FPTAN, // 53..60
  FX_FRNDINT, FX_FSCALE, FX_FPREM, FX_FPREM1            // 61..64
};

// ---- generalized stack-commit actions (mirror fpu_writeback.sv) -------------
enum {
  A_NONE = 0, A_TOP = 1, A_STI = 2, A_STI_POP = 3, A_ST1_POP = 4,
  A_FSTAT = 5, A_FSTAT_POP = 6, A_FSTAT_POP2 = 7, A_SINCOS = 8, A_PUSH = 9
};

// x87 group-op (q_f_aluop): 0=ADD 1=MUL 2=COM 3=COMP 4=SUB 5=SUBR 6=DIV 7=DIVR.
enum { OP_ADD=0, OP_MUL=1, OP_SUB=4, OP_SUBR=5, OP_DIV=6, OP_DIVR=7 };

// ---- floatx80 word <-> extFloat80_t -----------------------------------------
static inline extFloat80_t words_to_extF80(uint32_t lo, uint32_t mid, uint32_t hi) {
  extFloat80_t v;
  v.signif  = ((uint64_t)mid << 32) | lo;   // 64-bit significand
  v.signExp = (uint16_t)hi;                  // [15]=sign [14:0]=exp
  return v;
}
static inline void extF80_to_words(extFloat80_t v, uint32_t *lo, uint32_t *mid, uint32_t *hi) {
  *lo  = (uint32_t)(v.signif & 0xFFFFFFFFu);
  *mid = (uint32_t)(v.signif >> 32);
  *hi  = (uint32_t)v.signExp;
}

// x87 RC (fctrl[11:10]) -> SoftFloat rounding mode.
static uint_fast8_t rc_to_sf(unsigned rc) {
  switch (rc & 3u) {
    case 0:  return softfloat_round_near_even;  // nearest
    case 1:  return softfloat_round_min;        // toward -inf
    case 2:  return softfloat_round_max;        // toward +inf
    default: return softfloat_round_minMag;     // truncate (toward 0)
  }
}

// x87 PC (fctrl[9:8]) -> SoftFloat extF80_roundingPrecision (significand bits as
// the softfloat 32/64/80 codes). Setting this global makes extF80_add/sub/mul/div/
// sqrt round the result to 24/53/64-bit significand (single/double/extended),
// keeping the full extended exponent range -- exactly what real x87 does. fist /
// roundToInt / to-int conversions are NOT affected by this global, so they need no
// reset. Quake runs PC=00 (24-bit single); ignoring it diverged the per-frame math
// (accumulated low-bit error -> wrong FIST loop bound). [board-F5 root cause fix]
static uint_fast8_t pc_to_prec(unsigned pc) {
  switch (pc & 3u) {
    case 0:  return 32;   // 24-bit single
    case 2:  return 64;   // 53-bit double
    default: return 80;   // 64-bit extended (PC=11; reserved PC=01 -> extended)
  }
}

// Read the 80-bit operand at the given base DATA index (lo,mid,hi at idx, idx+1, idx+2).
static extFloat80_t read_op80(ven_rd_fn rd, ven_wr_fn wr, unsigned base) {
  uint32_t w[3];
  for (unsigned i = 0; i < 3; i++) { wr(VEN_R_FPT_IDX, base + i); w[i] = rd(VEN_R_FPT_DATA); }
  return words_to_extF80(w[0], w[1], w[2]);
}

// Write res0 (idx 0-2), res1 (idx 3-5), status (idx 6), then W1P commit with action.
static void commit(ven_rd_fn rd, ven_wr_fn wr, extFloat80_t res0, extFloat80_t res1,
                   uint16_t fstat, unsigned action) {
  (void)rd;
  uint32_t a0, a1, a2, b0, b1, b2;
  extF80_to_words(res0, &a0, &a1, &a2);
  extF80_to_words(res1, &b0, &b1, &b2);
  wr(VEN_R_FPT_IDX, 0); wr(VEN_R_FPT_RES, a0);
  wr(VEN_R_FPT_IDX, 1); wr(VEN_R_FPT_RES, a1);
  wr(VEN_R_FPT_IDX, 2); wr(VEN_R_FPT_RES, a2);
  wr(VEN_R_FPT_IDX, 3); wr(VEN_R_FPT_RES, b0);
  wr(VEN_R_FPT_IDX, 4); wr(VEN_R_FPT_RES, b1);
  wr(VEN_R_FPT_IDX, 5); wr(VEN_R_FPT_RES, b2);
  wr(VEN_R_FPT_IDX, 6); wr(VEN_R_FPT_RES, fstat);
  wr(VEN_R_FPT_CTRL, 1u | (action << VEN_FPT_ACT_SHIFT));
}

// ---- x87 status-word bit positions (used by the packers + helpers below) -----
#define FSW_C0 0x0100u
#define FSW_C1 0x0200u
#define FSW_C2 0x0400u
#define FSW_C3 0x4000u
#define FSW_IE 0x0001u
#define FSW_PE 0x0020u
#define FSW_CC_CLR (~(FSW_C0|FSW_C1|FSW_C2|FSW_C3))

// ---- store-value packers ----------------------------------------------------
// A narrowing store returns the PACKED destination BYTES (little-endian) in res0's
// 80-bit field. commit() serialises res0 as words[0]=signif[31:0], words[1]=
// signif[63:32], words[2]=signExp[15:0] -> exactly f_trap_store_q[31:0]/[63:32]/[79:64],
// the word order S_FSTORE writes to memory. So we stuff the packed value into
// {signExp:signif} = the low 80 bits and zero the rest.
static inline extFloat80_t pack_bytes32(uint32_t v) {
  extFloat80_t r; r.signif = (uint64_t)v; r.signExp = 0; return r;
}
static inline extFloat80_t pack_bytes64(uint64_t v) {
  extFloat80_t r; r.signif = v; r.signExp = 0; return r;
}
static inline extFloat80_t pack_bytes80(uint64_t lo64, uint16_t hi16) {
  extFloat80_t r; r.signif = lo64; r.signExp = hi16; return r;
}

// FBSTP: round ST0 to a 64-bit integer (per RC), then pack 18 packed-BCD digits +
// a sign byte into the 10-byte m80 image (byte 9 bit7 = sign; bytes 0-8 = 18 BCD
// digits, byte 0 = least significant pair). IE on out-of-BCD-range / invalid; PE on
// an inexact round-to-int. (Mirrors fx_fx_to_bcd: {ie,pe,bcd} -> fstat sticky.)
static extFloat80_t fbstp_pack(extFloat80_t v, uint_fast8_t rm, uint16_t *fstat, uint16_t fstat0) {
  softfloat_exceptionFlags = 0;
  int_fast64_t iv = extF80_to_i64(v, rm, false);   // exact==false -> inexact sets PE
  int invalid = (softfloat_exceptionFlags & softfloat_flag_invalid) ? 1 : 0;
  uint16_t f = fstat0;
  uint64_t mag; int neg = 0;
  if (iv < 0) { neg = 1; mag = (uint64_t)(-(iv + 1)) + 1ull; } else mag = (uint64_t)iv;
  // 18-digit packed BCD holds up to 999,999,999,999,999,999 (10^18 - 1). i64 magnitude
  // can exceed that -> BCD-range overflow == invalid (store the indefinite image).
  // Layout mirrors fx_fx_to_bcd: bcd[i*4+:4]=digit i (LSB-first, 18 nibbles in bits
  // [71:0]); bcd[79:72]=sign byte (0x80 / 0x00). The full 80-bit value maps to
  // {signExp=bits[79:64], signif=bits[63:0]} via pack_bytes80.
  if (invalid || mag >= 1000000000000000000ull) {
    // x87 packed-BCD integer indefinite = 0xFFFFC000000000000000.
    f |= FSW_IE; *fstat = f;
    return pack_bytes80(0xC000000000000000ull, 0xFFFFu);
  }
  uint8_t nib[20] = {0};            // 20 nibbles = bits[79:0]; nib[0..17]=digits
  for (int d = 0; d < 18 && mag; d++) { nib[d] = (uint8_t)(mag % 10ull); mag /= 10ull; }
  nib[19] = neg ? 0x8 : 0x0;        // sign byte high nibble (bits[79:76]); nib[18]=0
  if (softfloat_exceptionFlags & softfloat_flag_inexact) f |= FSW_PE;
  *fstat = f;
  uint64_t lo = 0; uint16_t hi = 0;
  for (int i = 0; i < 16; i++) lo |= (uint64_t)nib[i] << (4 * i);          // bits[63:0]
  for (int i = 0; i < 4;  i++) hi |= (uint16_t)nib[16 + i] << (4 * i);     // bits[79:64]
  return pack_bytes80(lo, hi);
}

// ---- x87 status-word helpers ------------------------------------------------
// fstat condition codes: C0=bit8, C1=bit9, C2=bit10, C3=bit14. Exception flags:
// IE=bit0, DE=bit1, ZE=bit2, OE=bit3, UE=bit4, PE=bit5. (FSW_* macros defined above.)
static int ext_is_nan(extFloat80_t v) {
  uint16_t exp = v.signExp & 0x7FFF;
  return exp == 0x7FFF && (v.signif << 1) != 0;
}

// FCOM/FUCOM/FTST/FICOM result: set C3/C2/C0 from the ordered compare of a vs b.
//   a>b -> all 0;  a<b -> C0;  a==b -> C3;  unordered -> C3+C2+C0.
// FCOM is signaling (sets IE on any NaN); FUCOM is quiet (IE only on signaling NaN).
static uint16_t compare_fstat(uint16_t fstat, extFloat80_t a, extFloat80_t b, int signaling) {
  uint16_t cc = fstat & FSW_CC_CLR;
  softfloat_exceptionFlags = 0;
  if (ext_is_nan(a) || ext_is_nan(b)) {
    cc |= FSW_C3 | FSW_C2 | FSW_C0;            // unordered
    // FCOM: any NaN -> IE. FUCOM: only signaling NaN -> IE.
    int sig_nan = (signaling) ? (ext_is_nan(a) || ext_is_nan(b))
                              : (extF80_isSignalingNaN(a) || extF80_isSignalingNaN(b));
    if (sig_nan) cc |= FSW_IE;
    return cc;
  }
  if (extF80_eq(a, b))      cc |= FSW_C3;       // equal
  else if (extF80_lt(a, b)) cc |= FSW_C0;       // a < b
  // a > b -> leave 0
  return cc;
}

// FXAM: classify ST0 (IA-32 SDM Vol.1 FXAM, the {C3,C2,C0} class triple; C1=sign):
//   Unsupported 000, NaN 001, Normal-finite 010, Infinity 011,
//   Zero 100, Empty 101, Denormal 110.
static uint16_t fxam_fstat(uint16_t fstat, extFloat80_t v, int empty) {
  uint16_t cc = fstat & FSW_CC_CLR;
  uint16_t exp = v.signExp & 0x7FFF;
  uint64_t man = v.signif;
  int sign = (v.signExp >> 15) & 1;
  unsigned c3 = 0, c2 = 0, c0 = 0;       // {c3,c2,c0}
  if (empty)                  { c3 = 1;          c0 = 1; }  // Empty    101
  else if (exp == 0x7FFF) {
    if ((man << 1) == 0)      {          c2 = 1; c0 = 1; }  // Infinity 011
    else                      {                  c0 = 1; }  // NaN      001
  } else if (exp == 0) {
    if (man == 0)             { c3 = 1;                  }  // Zero     100
    else                      { c3 = 1; c2 = 1;          }  // Denormal 110
  } else                      {          c2 = 1;          }  // Normal   010
  if (c3) cc |= FSW_C3;
  if (c2) cc |= FSW_C2;
  if (c0) cc |= FSW_C0;
  if (sign) cc |= FSW_C1;
  return cc;
}

// Merge SoftFloat's exception flags into fstat sticky bits (IE/PE the common ones).
static uint16_t merge_excep(uint16_t fstat) {
  uint16_t f = fstat;
  if (softfloat_exceptionFlags & softfloat_flag_invalid) f |= FSW_IE;
  if (softfloat_exceptionFlags & softfloat_flag_inexact) f |= FSW_PE;
  return f;
}

// extF80 <-> double via SoftFloat (avoids hand-rolled bit-twiddling; double carries
// the ~Quake-precision the transcendentals need — a future extF80 kernel can replace).
static double ext_to_d(extFloat80_t v) {
  union { float64_t f; double d; } u; u.f = extF80_to_f64(v); return u.d;
}
static extFloat80_t d_to_ext(double x) {
  union { double d; float64_t f; } u; u.d = x; return f64_to_extF80(u.f);
}

// Transcendental / FPREM bridge (libm doubles). FPATAN/FYL2X/FYL2XP1 write ST1+pop
// (A_ST1_POP); F2XM1/FSIN/FCOS/FRNDINT-like write ST0 (A_TOP); FSINCOS/FPTAN push
// a second value (A_SINCOS); FPREM writes ST0 + the q-bit codes (A_TOP).
static void ven_fp_ps_transc(ven_rd_fn rd, ven_wr_fn wr, unsigned op,
                      extFloat80_t st0, extFloat80_t st1, uint16_t fstat_in,
                      uint16_t fctrl, unsigned sti, unsigned pop) {
  (void)fctrl; (void)sti; (void)pop;
  double x = ext_to_d(st0), y = ext_to_d(st1), r = 0.0, r2 = 0.0;
  unsigned action = A_TOP;
  uint16_t fstat = fstat_in;            // preserve incoming sticky flags + cc
  switch (op) {
    case FX_FPATAN:  r = atan2(y, x);                 action = A_ST1_POP; break;
    case FX_FYL2X:   r = y * log2(x);                 action = A_ST1_POP; break;
    case FX_FYL2XP1: r = y * log2(1.0 + x);           action = A_ST1_POP; break;
    case FX_F2XM1:   r = exp2(x) - 1.0;               action = A_TOP;     break;
    case FX_FSIN:    r = sin(x);                      action = A_TOP;     break;
    case FX_FCOS:    r = cos(x);                      action = A_TOP;     break;
    case FX_FSINCOS: r = sin(x); r2 = cos(x);         action = A_SINCOS;  break; // ST0=sin, push cos
    case FX_FPTAN:   r = tan(x); r2 = 1.0;            action = A_SINCOS;  break; // ST0=tan, push 1.0
    case FX_FPREM: case FX_FPREM1: {
      r = (op == FX_FPREM1) ? remainder(x, y) : fmod(x, y);
      // C2=0 (complete), C0/C3/C1 = low 3 quotient bits (approx; Quake tolerant).
      long q = (long)llround((x - r) / y);
      fstat &= FSW_CC_CLR;                // clear C0-C3, then set the q-codes
      if (q & 1) fstat |= FSW_C1;
      if (q & 2) fstat |= FSW_C3;
      if (q & 4) fstat |= FSW_C0;
      action = A_TOP;
      break;
    }
    default: r = x; action = A_TOP; break;
  }
  extFloat80_t res0 = d_to_ext(r), res1 = d_to_ext(r2);
  commit(rd, wr, res0, res1, fstat, action);
}

void ven_fp_ps_service(ven_rd_fn rd, ven_wr_fn wr) {
  uint32_t stat   = rd(VEN_R_FPT_STAT);
  unsigned op     = (stat >> VEN_FPT_OP_SHIFT) & VEN_FPT_OP_MASK;

  extFloat80_t st0 = read_op80(rd, wr, 0);
  extFloat80_t st1 = read_op80(rd, wr, 3);
  extFloat80_t mem = read_op80(rd, wr, 6);
  wr(VEN_R_FPT_IDX, 9);  uint16_t fctrl  = (uint16_t)rd(VEN_R_FPT_DATA);
  wr(VEN_R_FPT_IDX, 10); uint32_t ctx    = rd(VEN_R_FPT_DATA);
  wr(VEN_R_FPT_IDX, 11); uint16_t fstat0 = (uint16_t)rd(VEN_R_FPT_DATA);  // live status word
  unsigned sti   = ctx & 0x7;
  unsigned pop   = (ctx >> 3) & 0x1;
  unsigned aluop = (ctx >> 4) & 0x7;

  softfloat_roundingMode = rc_to_sf((fctrl >> 10) & 3u);
  extF80_roundingPrecision = pc_to_prec((fctrl >> 8) & 3u);   // honor x87 precision control
  softfloat_exceptionFlags = 0;

  extFloat80_t res0 = st0, res1 = st0;   // res1 default unused
  uint16_t fstat = fstat0;               // start from the live status (preserve sticky+cc)
  unsigned action = A_TOP;

  // For arithmetic, the trap exposes only ST0/ST1/mem — the second operand for a
  // reg-form ST0,ST(i) op is ST(i), which the core places at the ST1 slot ONLY when
  // sti==1. To keep the first milestone tractable the PL maps ST(i) into the trap's
  // st1 view via the same fst() read the commit uses; sti!=1 reg-forms are handled
  // by the PL exposing fst(sti) as st1 (see core.sv fptrap_st1). Here st1 == ST(i).
  extFloat80_t a, b;

  switch (op) {
    // ---------------- binary arithmetic, dst = ST0 -----------------------------
    case FX_AR_ST0_STI:                 // ST0 op= ST(i)   (a=ST0, b=ST(i)=st1)
    case FX_AR_M32: case FX_AR_M64:     // ST0 op= mem float (b=mem)
    case FX_AR_I16: case FX_AR_I32: {   // ST0 op= mem int
      a = st0;
      if (op == FX_AR_M32 || op == FX_AR_M64) b = mem;
      else if (op == FX_AR_I16)               b = i32_to_extF80((int32_t)(int16_t)(mem.signif & 0xFFFFu));
      else if (op == FX_AR_I32)               b = i32_to_extF80((int32_t)(mem.signif & 0xFFFFFFFFu));
      else                                    b = st1;     // ST(i)
      switch (aluop) {
        case OP_ADD:  res0 = extF80_add(a, b); break;
        case OP_MUL:  res0 = extF80_mul(a, b); break;
        case OP_SUB:  res0 = extF80_sub(a, b); break;
        case OP_SUBR: res0 = extF80_sub(b, a); break;
        case OP_DIV:  res0 = extF80_div(a, b); break;
        case OP_DIVR: res0 = extF80_div(b, a); break;
        default:      res0 = a; break;
      }
      fstat = merge_excep(fstat0);
      action = A_TOP;
      break;
    }
    // ---------------- binary arithmetic, dst = ST(i) ---------------------------
    case FX_AR_STI_ST0: {               // ST(i) op= ST0   (a=ST(i)=st1, b=ST0)
      a = st1; b = st0;
      // The PL already reverse-encodes SUBR/DIVR into aluop for the STI form.
      switch (aluop) {
        case OP_ADD:  res0 = extF80_add(a, b); break;
        case OP_MUL:  res0 = extF80_mul(a, b); break;
        case OP_SUB:  res0 = extF80_sub(a, b); break;
        case OP_SUBR: res0 = extF80_sub(b, a); break;
        case OP_DIV:  res0 = extF80_div(a, b); break;
        case OP_DIVR: res0 = extF80_div(b, a); break;
        default:      res0 = a; break;
      }
      fstat = merge_excep(fstat0);
      action = pop ? A_STI_POP : A_STI;
      break;
    }
    // ---------------- unary ST0 ------------------------------------------------
    case FX_FSQRT:
      res0 = extF80_sqrt(st0);
      fstat = merge_excep(fstat0);
      action = A_TOP;
      break;
    case FX_FRNDINT:
      res0 = extF80_roundToInt(st0, softfloat_roundingMode, true /*exact->PE*/);
      fstat = merge_excep(fstat0);
      action = A_TOP;
      break;
    case FX_FSCALE: {                   // ST0 * 2^trunc(ST1)
      int64_t n = extF80_to_i64(st1, softfloat_round_minMag, false);
      // scalbn via repeated mul by 2 is exact for the power-of-two; use i64->extF80.
      // Build 2^n as extF80 by exponent patch (bounded; large |n| saturates).
      extFloat80_t two_n;
      if (n >= 16384)      { two_n.signif = 0x8000000000000000ull; two_n.signExp = 0x7FFE; }
      else if (n <= -16383){ two_n.signif = 0x8000000000000000ull; two_n.signExp = 0x0001; }
      else { int e = 16383 + (int)n; two_n.signif = 0x8000000000000000ull; two_n.signExp = (uint16_t)(e & 0x7FFF); }
      res0 = extF80_mul(st0, two_n);
      fstat = merge_excep(fstat0);
      action = A_TOP;
      break;
    }
    // ---------------- compares (status only) -----------------------------------
    case FX_FCOM_STI: case FX_FCOM_M32: case FX_FCOM_M64:
      b = (op == FX_FCOM_STI) ? st1 : mem;
      fstat = compare_fstat(fstat0, st0, b, /*signaling*/1);
      action = pop ? A_FSTAT_POP : A_FSTAT;
      break;
    case FX_FUCOM_STI:
      fstat = compare_fstat(fstat0, st0, st1, /*signaling*/0);
      action = pop ? A_FSTAT_POP : A_FSTAT;
      break;
    case FX_FCOMPP:
      fstat = compare_fstat(fstat0, st0, st1, 1);
      action = A_FSTAT_POP2;
      break;
    case FX_FUCOMPP:
      fstat = compare_fstat(fstat0, st0, st1, 0);
      action = A_FSTAT_POP2;
      break;
    case FX_FTST: {
      extFloat80_t zero = ui32_to_extF80(0);
      fstat = compare_fstat(fstat0, st0, zero, 1);
      action = A_FSTAT;
      break;
    }
    case FX_FICOM_M16: case FX_FICOM_M32: {
      int32_t iv = (op == FX_FICOM_M16) ? (int32_t)(int16_t)(mem.signif & 0xFFFFu)
                                        : (int32_t)(mem.signif & 0xFFFFFFFFu);
      b = i32_to_extF80(iv);
      fstat = compare_fstat(fstat0, st0, b, 1);
      action = pop ? A_FSTAT_POP : A_FSTAT;
      break;
    }
    case FX_FXAM:
      fstat = fxam_fstat(fstat0, st0, /*empty*/0);
      action = A_FSTAT;
      break;
    // ---------------- widening LOADS (mem -> floatx80, push) -------------------
    // FP_PS_ALL traps these so the m32/m64/int -> extF80 conversion runs on the A53
    // (the 74-level FP-load setup cone leaves the PL). res0 = the assembled extF80;
    // A_PUSH does ftop--, ST0<=res0. mem holds the raw bytes (lo/mid/hi words):
    //   FLD  m32 -> f32 in mem.signif[31:0];  FLD m64 -> f64 in mem.signif[63:0].
    //   FILD m16/m32 -> sign-extended int in mem.signif low bits; m64 -> i64.
    case FX_FLD_M32: {
      union { uint32_t u; float32_t f; } c; c.u = (uint32_t)(mem.signif & 0xFFFFFFFFu);
      res0 = f32_to_extF80(c.f);
      fstat = merge_excep(fstat0);   // a widening f32->extF80 is exact (flags clear)
      action = A_PUSH; break;
    }
    case FX_FLD_M64: {
      union { uint64_t u; float64_t f; } c; c.u = mem.signif;
      res0 = f64_to_extF80(c.f);
      fstat = merge_excep(fstat0);
      action = A_PUSH; break;
    }
    case FX_FILD_M16:
      res0 = i32_to_extF80((int32_t)(int16_t)(mem.signif & 0xFFFFu));
      fstat = fstat0; action = A_PUSH; break;
    case FX_FILD_M32:
      res0 = i32_to_extF80((int32_t)(uint32_t)(mem.signif & 0xFFFFFFFFu));
      fstat = fstat0; action = A_PUSH; break;
    case FX_FILD_M64:
      res0 = i64_to_extF80((int64_t)mem.signif);
      fstat = fstat0; action = A_PUSH; break;
    case FX_FBLD: {
      // packed-BCD m80 -> extF80 (exact, <=18 digits). mem holds the 80-bit image:
      // signif[63:0]=bytes 0-7, signExp[15:0]=bytes 8-9. Nibble i (bits[i*4+:4]) is
      // decimal digit i (LSB-first, 18 digits in bits[71:0]); bit 79 = sign.
      // value = (-1)^sign * sum(digit_i * 10^i). <18 digits => |v| < 10^18 < 2^63.
      uint64_t lo = mem.signif; uint16_t hi = mem.signExp;
      int64_t val = 0; int64_t pow10 = 1;
      for (int i = 0; i < 16; i++) { val += (int64_t)((lo >> (4*i)) & 0xF) * pow10; pow10 *= 10; }
      for (int i = 0; i < 2;  i++) { val += (int64_t)((hi >> (4*i)) & 0xF) * pow10; pow10 *= 10; }
      if (hi & 0x8000) val = -val;     // sign byte (bits[79:72]) bit 7 == hi bit 15
      res0 = i64_to_extF80(val);
      fstat = fstat0; action = A_PUSH; break;
    }
    // ---------------- narrowing STORES (ST0 -> mem bytes) ----------------------
    // FP_PS_ALL traps these so the extF80 -> f32/f64/int/bcd narrowing runs on the
    // A53 (the 356-level FST setup cone leaves the PL). The RTL routes a store-trap to
    // S_FSTORE and writes f_trap_store_q = fptrap_result, so res0 carries the PACKED
    // little-endian destination BYTES (in the low 80 bits) + the status word. The
    // stack action is irrelevant for stores (the RTL ignores it on f_ps_store_trap),
    // and only the trap-commit's unconditional fp_we_fstat<=res_fstat matters here, so
    // A_NONE leaves the fpr untouched while the sticky flags land. The FSTP/FISTP pop
    // is driven by the RTL on the last S_FSTORE beat, not here.
    case FX_FST_M32: {
      float32_t f = extF80_to_f32(st0);
      res0 = pack_bytes32(f.v);
      fstat = merge_excep(fstat0); action = A_NONE; break;
    }
    case FX_FST_M64: {
      float64_t f = extF80_to_f64(st0);
      res0 = pack_bytes64(f.v);
      fstat = merge_excep(fstat0); action = A_NONE; break;
    }
    case FX_FIST_M16: {
      int_fast32_t v = extF80_to_i32(st0, softfloat_roundingMode, false);
      res0 = pack_bytes64((uint64_t)(uint16_t)(int16_t)v);
      fstat = merge_excep(fstat0); action = A_NONE; break;
    }
    case FX_FIST_M32: {
      int_fast32_t v = extF80_to_i32(st0, softfloat_roundingMode, false);
      res0 = pack_bytes64((uint64_t)(uint32_t)v);
      fstat = merge_excep(fstat0); action = A_NONE; break;
    }
    case FX_FIST_M64: {
      int_fast64_t v = extF80_to_i64(st0, softfloat_roundingMode, false);
      res0 = pack_bytes64((uint64_t)v);
      fstat = merge_excep(fstat0); action = A_NONE; break;
    }
    case FX_FBSTP: {
      // packed-BCD m80: 18 decimal digits (9 bytes) + sign byte at byte 9.
      res0 = fbstp_pack(st0, softfloat_roundingMode, &fstat, fstat0);
      action = A_NONE; break;
    }
    // ---------------- transcendentals ------------------------------------------
    // NOTE: SoftFloat has no transcendental kernels; these use libm doubles via a
    // floatx80<->double bridge for now (Quake-precision adequate; res via f64). A
    // future pass can add an extF80 transcendental kernel (tools/p5xtrans qref).
    case FX_FPATAN: case FX_FYL2X: case FX_FYL2XP1:
    case FX_F2XM1:  case FX_FSIN:  case FX_FCOS:
    case FX_FSINCOS:case FX_FPTAN:
    case FX_FPREM:  case FX_FPREM1:
      // Deferred to the libm-bridge handler in ven_soc_app.c (ven_fp_ps_transc()).
      // For the area/WHS milestone these are reachable but rare in the FP gate.
      ven_fp_ps_transc(rd, wr, op, st0, st1, fstat0, fctrl, sti, pop);
      return;
    default:
      // Unknown/data-movement op should not trap; commit a no-op (status passthrough).
      action = A_FSTAT;
      fstat = 0;
      break;
  }

  commit(rd, wr, res0, res1, fstat, action);
}
