// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// test_fp_ps.c — host smoke test for the FP_PS_ALL x87 dispatcher (ven_fp_ps.c).
// Mocks the AXIL R_FPT_* window with a register array, drives a few ops, and checks
// the committed result + action. NOT linked into ven_soc_app; build with:
//   gcc -I<sf>/include -I<sf-build> test_fp_ps.c ven_fp_ps.c <softfloat.a> -lm
// (See the run-fp-ps-gate.sh wrapper.)

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "softfloat.h"
#include "ven_soc_regs.h"
#include "ven_fp_ps.h"

// ---- mock window ------------------------------------------------------------
static uint32_t g_st0[3], g_st1[3], g_mem[3], g_fctrl, g_ctx, g_op;
static uint32_t g_res0[3], g_res1[3], g_resfstat, g_action, g_committed;
static unsigned g_idx;

static uint32_t mock_rd(uint32_t off) {
  switch (off) {
    case VEN_R_FPT_STAT: return (g_op << VEN_FPT_OP_SHIFT) | VEN_FPT_STAT_ACTIVE;
    case VEN_R_FPT_DATA:
      switch (g_idx) {
        case 0: case 1: case 2: return g_st0[g_idx];
        case 3: case 4: case 5: return g_st1[g_idx - 3];
        case 6: case 7: case 8: return g_mem[g_idx - 6];
        case 9: return g_fctrl;
        case 10: return g_ctx;
        default: return 0;
      }
    default: return 0;
  }
}
static void mock_wr(uint32_t off, uint32_t v) {
  switch (off) {
    case VEN_R_FPT_IDX:  g_idx = v & 0xF; break;
    case VEN_R_FPT_RES:
      if (g_idx < 3) g_res0[g_idx] = v;
      else if (g_idx < 6) g_res1[g_idx - 3] = v;
      else if (g_idx == 6) g_resfstat = v;
      break;
    case VEN_R_FPT_CTRL: g_committed = 1; g_action = (v >> VEN_FPT_ACT_SHIFT) & 0xF; break;
  }
}

// ---- floatx80 <-> double for test setup/check -------------------------------
static void d_to_x80(double v, uint32_t *w) {
  int sign = signbit(v) ? 1 : 0; if (sign) v = -v;
  uint64_t mant; uint32_t hi;
  if (v == 0.0)      { mant = 0; hi = 0; }
  else if (isinf(v)) { mant = 0x8000000000000000ull; hi = 0x7FFF; }
  else { int e; double m = frexp(v, &e); uint64_t s = (uint64_t)ldexp(m, 64);
         mant = s; hi = (uint32_t)(e + 16382); }
  w[0] = (uint32_t)(mant & 0xFFFFFFFFu); w[1] = (uint32_t)(mant >> 32);
  w[2] = ((uint32_t)sign << 15) | hi;
}
static double x80_to_d(const uint32_t *w) {
  int sign = (w[2] >> 15) & 1; int exp = w[2] & 0x7FFF;
  uint64_t mant = ((uint64_t)w[1] << 32) | w[0];
  double val;
  if (exp == 0x7FFF) val = (mant << 1) == 0 ? INFINITY : NAN;
  else if (exp == 0 && mant == 0) val = 0.0;
  else val = ldexp((double)mant, exp - 16383 - 63);
  return sign ? -val : val;
}

static int fails = 0;
static void chk(const char *name, double got, double want) {
  double tol = fabs(want) * 1e-12 + 1e-12;
  if (fabs(got - want) > tol) { printf("FAIL %s: got %.17g want %.17g\n", name, got, want); fails++; }
  else                          printf("ok   %s: %.17g\n", name, got);
}

static void setup(unsigned op, double st0, double st1, double mem,
                  unsigned sti, unsigned pop, unsigned aluop, unsigned rc) {
  memset(g_res0,0,sizeof g_res0); memset(g_res1,0,sizeof g_res1);
  g_resfstat = 0; g_committed = 0; g_action = 0;
  g_op = op; d_to_x80(st0,g_st0); d_to_x80(st1,g_st1); d_to_x80(mem,g_mem);
  g_fctrl = (rc & 3) << 10;
  g_ctx = (aluop << 4) | (pop << 3) | (sti & 7);
}

enum { FX_AR_ST0_STI=40, FX_AR_STI_ST0=41, FX_AR_M32=42, FX_FSQRT=46,
       FX_FCOM_STI=32, FX_FTST=36,
       FX_FLD_M32=1, FX_FLD_M64=2, FX_FILD_M16=5, FX_FILD_M32=6, FX_FILD_M64=7,
       FX_FST_M32=9, FX_FST_M64=10, FX_FIST_M16=13, FX_FIST_M32=14, FX_FIST_M64=15,
       FX_FBSTP=48, FX_FBLD=47 };
enum { A_NONE=0, A_TOP=1, A_PUSH=9 };
enum { OP_ADD=0, OP_MUL=1, OP_SUB=4, OP_DIV=6 };

// set the raw mem words (for load tests: the f32/f64/int bytes the PL assembled in f_mem80)
static void set_mem_words(uint32_t lo, uint32_t mid, uint32_t hi) {
  g_mem[0]=lo; g_mem[1]=mid; g_mem[2]=hi;
}
// reassemble the committed 80-bit res0 as the packed store bytes (lo64 + hi16)
static void res0_bytes(uint64_t *lo, uint16_t *hi) {
  *lo = ((uint64_t)g_res0[1] << 32) | g_res0[0]; *hi = (uint16_t)g_res0[2];
}

int main(void) {
  // ST0 = ST0 + ST(i)
  setup(FX_AR_ST0_STI, 3.5, 1.25, 0, 1, 0, OP_ADD, 0);
  ven_fp_ps_service(mock_rd, mock_wr);
  chk("FADD ST0,ST1", x80_to_d(g_res0), 4.75);

  // ST0 = ST0 * mem
  setup(FX_AR_M32, 2.0, 0, 21.0, 0, 0, OP_MUL, 0);
  ven_fp_ps_service(mock_rd, mock_wr);
  chk("FMUL ST0,mem", x80_to_d(g_res0), 42.0);

  // ST0 = ST0 / ST(i)
  setup(FX_AR_ST0_STI, 1.0, 4.0, 0, 1, 0, OP_DIV, 0);
  ven_fp_ps_service(mock_rd, mock_wr);
  chk("FDIV ST0,ST1", x80_to_d(g_res0), 0.25);

  // ---- PRECISION CONTROL (board-F5 fix) -------------------------------------
  // 1.0 + 2^-30: the 2^-30 bit is below 24-bit single precision but within 64-bit
  // extended. At PC=00 (single, Quake's setting) the result rounds to EXACTLY 1.0;
  // at PC=11 (extended) it keeps 1.0000000009. This DIRECTLY proves ven_fp_ps.c
  // honors fctrl[9:8] (without the fix, both would keep the bit -> the PC=24 case
  // FAILs, which is the board-F5 divergence).
  setup(FX_AR_ST0_STI, 1.0, ldexp(1.0, -30), 0, 1, 0, OP_ADD, 0);   // setup() -> PC=00 single
  ven_fp_ps_service(mock_rd, mock_wr);
  chk("FADD PC24 1+2^-30 -> 1.0", x80_to_d(g_res0), 1.0);

  setup(FX_AR_ST0_STI, 1.0, ldexp(1.0, -30), 0, 1, 0, OP_ADD, 0);
  g_fctrl |= (3u << 8);                                             // PC=11 extended
  ven_fp_ps_service(mock_rd, mock_wr);
  chk("FADD PC64 1+2^-30 -> kept", x80_to_d(g_res0), 1.0 + ldexp(1.0, -30));

  // FSQRT
  setup(FX_FSQRT, 144.0, 0, 0, 0, 0, 0, 0);
  ven_fp_ps_service(mock_rd, mock_wr);
  chk("FSQRT", x80_to_d(g_res0), 12.0);

  // FCOM ST0 < ST1 -> C0 set (bit8)
  setup(FX_FCOM_STI, 1.0, 2.0, 0, 1, 0, 0, 0);
  ven_fp_ps_service(mock_rd, mock_wr);
  printf("%-5s FCOM 1<2 fstat=0x%04x (expect C0=0x100)\n",
         (g_resfstat & 0x100) ? "ok" : "FAIL", g_resfstat);
  if (!(g_resfstat & 0x100)) fails++;

  // FTST of 0.0 -> C3 set (equal)
  setup(FX_FTST, 0.0, 0, 0, 0, 0, 0, 0);
  ven_fp_ps_service(mock_rd, mock_wr);
  printf("%-5s FTST 0 fstat=0x%04x (expect C3=0x4000)\n",
         (g_resfstat & 0x4000) ? "ok" : "FAIL", g_resfstat);
  if (!(g_resfstat & 0x4000)) fails++;

  // ---- widening LOADS (mem -> floatx80, A_PUSH) ----------------------------
  // FLD m32: store the float32 bits of 1.5 in mem word0.
  { union { float f; uint32_t u; } c; c.f = 1.5f;
    setup(FX_FLD_M32, 0,0,0, 0,0,0,0); set_mem_words(c.u,0,0);
    ven_fp_ps_service(mock_rd, mock_wr);
    chk("FLD m32 (1.5)", x80_to_d(g_res0), 1.5);
    if (g_action != A_PUSH) { printf("FAIL FLD m32 action=%u (want A_PUSH)\n", g_action); fails++; } }
  // FLD m64: float64 bits of -3.25 in mem words 0,1.
  { union { double d; uint64_t u; } c; c.d = -3.25;
    setup(FX_FLD_M64, 0,0,0, 0,0,0,0);
    set_mem_words((uint32_t)c.u, (uint32_t)(c.u>>32), 0);
    ven_fp_ps_service(mock_rd, mock_wr);
    chk("FLD m64 (-3.25)", x80_to_d(g_res0), -3.25);
    if (g_action != A_PUSH) { printf("FAIL FLD m64 action=%u\n", g_action); fails++; } }
  // FILD m16: -7 as sign-extended int16.
  { setup(FX_FILD_M16, 0,0,0, 0,0,0,0); set_mem_words((uint32_t)(uint16_t)(int16_t)-7,0,0);
    ven_fp_ps_service(mock_rd, mock_wr);
    chk("FILD m16 (-7)", x80_to_d(g_res0), -7.0);
    if (g_action != A_PUSH) { printf("FAIL FILD m16 action=%u\n", g_action); fails++; } }
  // FILD m32: 1000000.
  { setup(FX_FILD_M32, 0,0,0, 0,0,0,0); set_mem_words(1000000u,0,0);
    ven_fp_ps_service(mock_rd, mock_wr);
    chk("FILD m32 (1e6)", x80_to_d(g_res0), 1000000.0); }
  // FILD m64: 5000000000 (> 2^32).
  { uint64_t v = 5000000000ull;
    setup(FX_FILD_M64, 0,0,0, 0,0,0,0); set_mem_words((uint32_t)v,(uint32_t)(v>>32),0);
    ven_fp_ps_service(mock_rd, mock_wr);
    chk("FILD m64 (5e9)", x80_to_d(g_res0), 5000000000.0); }
  // FBLD: packed-BCD -42 -> nibbles 0x42 in low bytes, sign bit79 set.
  { setup(FX_FBLD, 0,0,0, 0,0,0,0);
    set_mem_words(0x00000042u, 0x00000000u, 0x00008000u);  // digits 4,2 -> 42; hi bit15=sign
    ven_fp_ps_service(mock_rd, mock_wr);
    chk("FBLD (-42)", x80_to_d(g_res0), -42.0);
    if (g_action != A_PUSH) { printf("FAIL FBLD action=%u\n", g_action); fails++; } }
  // FBLD: packed-BCD 1234567 (digits across the low 7 nibbles), positive.
  { setup(FX_FBLD, 0,0,0, 0,0,0,0);
    set_mem_words(0x01234567u, 0x00000000u, 0x00000000u);
    ven_fp_ps_service(mock_rd, mock_wr);
    chk("FBLD (1234567)", x80_to_d(g_res0), 1234567.0); }

  // ---- narrowing STORES (ST0 -> packed bytes, A_NONE) ----------------------
  // FST m32: store 2.5 -> word0 == float32(2.5).
  { setup(FX_FST_M32, 2.5, 0,0, 0,0,0,0);
    ven_fp_ps_service(mock_rd, mock_wr);
    uint64_t lo; uint16_t hi; res0_bytes(&lo,&hi);
    union { uint32_t u; float f; } c; c.u = (uint32_t)lo;
    printf("%-5s FST m32 -> %.17g (want 2.5) action=%u\n", (c.f==2.5f && g_action==A_NONE)?"ok":"FAIL", (double)c.f, g_action);
    if (!(c.f==2.5f && g_action==A_NONE)) fails++; }
  // FST m64: store -123.5 -> words0,1 == float64(-123.5).
  { setup(FX_FST_M64, -123.5, 0,0, 0,0,0,0);
    ven_fp_ps_service(mock_rd, mock_wr);
    uint64_t lo; uint16_t hi; res0_bytes(&lo,&hi);
    union { uint64_t u; double d; } c; c.u = lo;
    printf("%-5s FST m64 -> %.17g (want -123.5)\n", (c.d==-123.5)?"ok":"FAIL", c.d);
    if (c.d != -123.5) fails++; }
  // FIST m32: store 42.0 (RC=nearest) -> low word == 42.
  { setup(FX_FIST_M32, 42.0, 0,0, 0,0,0,0);
    ven_fp_ps_service(mock_rd, mock_wr);
    uint64_t lo; uint16_t hi; res0_bytes(&lo,&hi);
    printf("%-5s FIST m32 -> %u (want 42)\n", ((uint32_t)lo==42u)?"ok":"FAIL", (uint32_t)lo);
    if ((uint32_t)lo != 42u) fails++; }
  // FIST m16: store -5 -> low 16 bits == 0xFFFB.
  { setup(FX_FIST_M16, -5.0, 0,0, 0,0,0,0);
    ven_fp_ps_service(mock_rd, mock_wr);
    uint64_t lo; uint16_t hi; res0_bytes(&lo,&hi);
    printf("%-5s FIST m16 -> 0x%04x (want 0xfffb)\n", ((uint16_t)lo==0xFFFBu)?"ok":"FAIL", (uint16_t)lo);
    if ((uint16_t)lo != 0xFFFBu) fails++; }
  // FBSTP: store 12345 -> packed BCD low bytes 0x...00012345.
  { setup(FX_FBSTP, 12345.0, 0,0, 0,0,0,0);
    ven_fp_ps_service(mock_rd, mock_wr);
    uint64_t lo; uint16_t hi; res0_bytes(&lo,&hi);
    int ok = ((lo & 0xFFFFFull) == 0x12345ull) && (hi == 0);
    printf("%-5s FBSTP 12345 -> lo=0x%016llx hi=0x%04x (want lo low=0x12345)\n",
           ok?"ok":"FAIL", (unsigned long long)lo, hi);
    if (!ok) fails++; }
  // FBSTP negative: -42 -> sign byte (bit 79) set, digits 0x42.
  { setup(FX_FBSTP, -42.0, 0,0, 0,0,0,0);
    ven_fp_ps_service(mock_rd, mock_wr);
    uint64_t lo; uint16_t hi; res0_bytes(&lo,&hi);
    int ok = ((lo & 0xFFull) == 0x42ull) && ((hi & 0x8000u) != 0);
    printf("%-5s FBSTP -42 -> lo=0x%016llx hi=0x%04x (want digits 0x42, sign bit15 of hi)\n",
           ok?"ok":"FAIL", (unsigned long long)lo, hi);
    if (!ok) fails++; }

  // ---- BULK DIFFERENTIAL: board FP path at PC=24/53/64 vs inline SoftFloat -------
  // Drives random arith (normals/denormals/zero/Inf/NaN) through ven_fp_ps_service at
  // all 3 precision-control modes and bit-exact-compares the 80-bit result to SoftFloat
  // with the matching extF80_roundingPrecision. The math is SoftFloat both sides, so a
  // mismatch = a PLUMBING or PC-WIRING bug in the PS handler (operand read order,
  // result pack, fctrl[9:8] decode) — the board's actual FP path, thoroughly exercised.
  {
    static uint64_t s = 0x9E3779B97F4A7C15ull;
    #define LCG32 ( s = s*6364136223846793005ull + 1442695040888963407ull, (uint32_t)(s>>33) )
    const unsigned   PCb[3]   = {0u, 2u, 3u};   // fctrl[9:8]: 24 / 53 / 64-bit
    const uint_fast8_t PREC[3] = {32u, 64u, 80u};
    const unsigned   ALU[4]   = {OP_ADD, OP_SUB, OP_MUL, OP_DIV};
    long n = 0; int dfail = 0;
    for (long it = 0; it < 90000; it++) {
      uint32_t w[2][3];
      for (int o = 0; o < 2; o++) {
        uint32_t lo = LCG32, mid = LCG32, k = LCG32; unsigned sign = (k >> 20) & 1, cls = k % 100;
        uint16_t exp; uint64_t man;
        if      (cls < 68) { exp = 1u + (LCG32 % 0x7FFDu); man = (1ull<<63) | (((uint64_t)mid<<32)|lo); }   // normal
        else if (cls < 85) { man = (((uint64_t)mid<<32)|lo) >> 1; if (!man) man = 1; exp = 0; }             // denormal
        else if (cls < 92) { exp = 0; man = 0; }                                                            // zero
        else if (cls < 97) { exp = 0x7FFF; man = (1ull<<63); }                                              // Inf
        else               { exp = 0x7FFF; man = (1ull<<63) | ((((uint64_t)mid<<32)|lo) >> 2) | 1; }        // NaN
        w[o][0] = (uint32_t)man; w[o][1] = (uint32_t)(man>>32); w[o][2] = ((unsigned)sign<<15)|exp;
      }
      unsigned pci = LCG32 % 3u, rc = LCG32 & 3u, op = ALU[LCG32 % 4u];
      memcpy(g_st0, w[0], sizeof w[0]); memcpy(g_st1, w[1], sizeof w[1]);
      g_op = FX_AR_ST0_STI; g_ctx = (op << 4) | 1u; g_fctrl = (rc << 10) | (PCb[pci] << 8);
      memset(g_res0, 0, sizeof g_res0); g_committed = 0;
      ven_fp_ps_service(mock_rd, mock_wr);

      extFloat80_t a, b, g;
      a.signExp = (uint16_t)w[0][2]; a.signif = ((uint64_t)w[0][1]<<32)|w[0][0];
      b.signExp = (uint16_t)w[1][2]; b.signif = ((uint64_t)w[1][1]<<32)|w[1][0];
      switch (rc & 3) { case 0: softfloat_roundingMode=softfloat_round_near_even; break;
        case 1: softfloat_roundingMode=softfloat_round_min; break;
        case 2: softfloat_roundingMode=softfloat_round_max; break;
        default: softfloat_roundingMode=softfloat_round_minMag; }
      extF80_roundingPrecision = PREC[pci];
      switch (op) { case OP_ADD: g=extF80_add(a,b); break; case OP_SUB: g=extF80_sub(a,b); break;
        case OP_MUL: g=extF80_mul(a,b); break; default: g=extF80_div(a,b); break; }
      uint32_t g0=(uint32_t)g.signif, g1=(uint32_t)(g.signif>>32), g2=(uint16_t)g.signExp;
      if (g_res0[0]!=g0 || g_res0[1]!=g1 || (g_res0[2]&0xFFFFu)!=(g2&0xFFFFu)) {
        if (dfail++ < 8)
          printf("DIFF op=%u pc=%u rc=%u: got %04x%08x%08x want %04x%08x%08x\n",
                 op, PCb[pci], rc, g_res0[2]&0xFFFFu, g_res0[1], g_res0[0], g2&0xFFFFu, g1, g0);
      }
      n++;
    }
    printf("%-5s PS bulk differential: %ld vectors (PC=24/53/64 x add/sub/mul/div), %d fails\n",
           dfail ? "FAIL" : "ok", n, dfail);
    if (dfail) fails++;
  }

  printf(fails ? "\nFP-PS GATE: %d FAIL\n" : "\nFP-PS GATE: PASS\n", fails);
  return fails ? 1 : 0;
}
