// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// =============================================================================
// ven_fpu_oracle — independent IEEE-754 / x87 reference for the fpu87 suite.
//
// Links Berkeley SoftFloat-3e's 80-bit extended type (extF80) and computes the
// EXACT result + IEEE exception flags for the x87 arithmetic the generator
// emits, INDEPENDENT of QEMU. The fpu87 gate uses it to TRIANGULATE the QEMU
// golden (SoftFloat <-> QEMU <-> RTL): the authoritative RTL-vs-QEMU diff is
// compare.py; this oracle additionally proves the QEMU golden's st0 data result
// is itself IEEE-correct, and flags any QEMU<->SoftFloat divergence (typically
// in the x87 "unsupported operand" corners: pseudo-denormals / unnormals).
//
// SoftFloat's extF80 behaviour is specialization-independent for the ops we use:
// s_propagateNaNExtF80UI.c is byte-identical between the 8086 and 8086-SSE specs
// (verified), and conversions go through the shared commonNaN path, so the
// library is built with the clean-compiling 8086-SSE spec with no loss of x87
// fidelity. See verif/fpu87/README.md.
//
// PROTOCOL (batch, line-oriented — one QEMU/RTL-free compute per line):
//   stdin : "<op> <rc> <a80> [<b80>]"      (one test vector per line)
//   stdout: "<r80> <xsw6>"                 (result + x87 status low 6 bits)
//             or "SKIP 00" for ops with no independent extF80 reference.
//
//   <op>  : add sub mul div sqrt rem1 rndint abs chs  (independent)
//           rem scale extract                          (-> SKIP: QEMU-only)
//   <rc>  : x87 rounding control 0=RNE 1=down 2=up 3=trunc
//   <aNN> : 20 hex chars = signExp(4) || signif(16), matching qref's emit().
//   <r80> : 20 hex chars, same encoding.
//   <xsw6>: 2 hex chars = x87 status-word exception bits PE UE OE ZE DE IE
//             bit0 IE(invalid) bit1 DE(denormal-operand) bit2 ZE(zero-divide)
//             bit3 OE(overflow) bit4 UE(underflow) bit5 PE(precision/inexact)
//
// Single-shot mode also works: argv = "<op> <rc> <a80> [<b80>]".
// =============================================================================
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "softfloat.h"

// ---- x87 status-word exception bits -----------------------------------------
enum { X_IE = 1, X_DE = 2, X_ZE = 4, X_OE = 8, X_UE = 16, X_PE = 32 };

// ---- 80-bit pack/parse (qref-compatible 20-hex encoding) --------------------
static extFloat80_t parse80(const char *s) {
    // s is exactly 20 hex chars: top 4 = signExp, low 16 = signif.
    char se[5];
    memcpy(se, s, 4); se[4] = 0;
    extFloat80_t x;
    x.signExp = (uint16_t)strtoul(se, NULL, 16);
    x.signif  = (uint64_t)strtoull(s + 4, NULL, 16);
    return x;
}
static void print80(extFloat80_t x, unsigned xsw) {
    printf("%04x%016llx %02x\n",
           (unsigned)(x.signExp & 0xFFFF),
           (unsigned long long)x.signif, xsw & 0x3F);
}

// ---- helpers ----------------------------------------------------------------
static int rc_x87_to_sf(int rc) {
    switch (rc & 3) {
        case 0: return softfloat_round_near_even; // RNE
        case 1: return softfloat_round_min;        // toward -inf
        case 2: return softfloat_round_max;        // toward +inf
        default: return softfloat_round_minMag;    // toward zero (truncate)
    }
}
static int is_denormal80(extFloat80_t x) {
    return ((x.signExp & 0x7FFF) == 0) && (x.signif != 0);
}

// Map SoftFloat's exception flags to the x87 status-word low 6 bits, and OR in
// DE for any denormal source operand (SoftFloat has no separate denormal flag;
// x87 raises DE on denormal operands for arithmetic).
static unsigned sf_to_x87sw(unsigned sf, int de) {
    unsigned x = 0;
    if (sf & softfloat_flag_invalid)   x |= X_IE;
    if (sf & softfloat_flag_infinite)  x |= X_ZE;   // "divide by zero"
    if (sf & softfloat_flag_overflow)  x |= X_OE;
    if (sf & softfloat_flag_underflow) x |= X_UE;
    if (sf & softfloat_flag_inexact)   x |= X_PE;
    if (de) x |= X_DE;
    return x;
}

// x87 precision control (PC, fctrl[9:8]) -> SoftFloat extF80_roundingPrecision.
// Set once from the FPU_PREC env (24/53/64-bit significand == 32/64/80 softfloat),
// default 80 (extended) so existing callers are byte-identical. This lets the
// oracle produce the PC=24/53 golden Quake actually runs under (the board-F5 bug).
static uint_fast8_t g_prec = 80;

// ---- one vector -------------------------------------------------------------
static int compute(const char *op, int rc, const char *a_s, const char *b_s) {
    softfloat_roundingMode  = (uint_fast8_t)rc_x87_to_sf(rc);
    extF80_roundingPrecision = g_prec;
    softfloat_exceptionFlags = 0;
    extFloat80_t a = parse80(a_s);
    extFloat80_t b = {0, 0};
    int have_b = (b_s != NULL && b_s[0]);
    if (have_b) b = parse80(b_s);
    int de = is_denormal80(a) || (have_b && is_denormal80(b));

    extFloat80_t r;
    if      (!strcmp(op, "add"))  r = extF80_add(a, b);
    else if (!strcmp(op, "sub"))  r = extF80_sub(a, b);
    else if (!strcmp(op, "mul"))  r = extF80_mul(a, b);
    else if (!strcmp(op, "div"))  r = extF80_div(a, b);
    else if (!strcmp(op, "sqrt")) r = extF80_sqrt(a);
    else if (!strcmp(op, "rem1")) r = extF80_rem(a, b);          // IEEE rem (FPREM1, fully reduced)
    else if (!strcmp(op, "rndint")) r = extF80_roundToInt(a, (uint_fast8_t)rc_x87_to_sf(rc), true);
    else if (!strcmp(op, "abs")) { r = a; r.signExp &= 0x7FFF; }
    else if (!strcmp(op, "chs")) { r = a; r.signExp ^= 0x8000; }
    else { printf("SKIP 00\n"); return 0; }                       // rem/scale/extract -> QEMU-only

    print80(r, sf_to_x87sw((unsigned)softfloat_exceptionFlags, de));
    return 0;
}

int main(int argc, char **argv) {
    const char *pe = getenv("FPU_PREC");
    if (pe) {
        int p = atoi(pe);  // x87 significand bits: 24=single 53=double 64=extended
        g_prec = (p==24) ? 32 : (p==53) ? 64 : 80;   // -> softfloat extF80 codes
    }
    if (argc >= 4) {  // single-shot: op rc a [b]
        return compute(argv[1], atoi(argv[2]), argv[3], argc >= 5 ? argv[4] : NULL);
    }
    // batch mode: read stdin lines "op rc a [b]"
    char line[256];
    while (fgets(line, sizeof line, stdin)) {
        char op[32], a[32], b[32];
        int rc;
        int n = sscanf(line, "%31s %d %31s %31s", op, &rc, a, b);
        if (n < 3) { printf("SKIP 00\n"); continue; }
        compute(op, rc, a, n >= 4 ? b : NULL);
    }
    return 0;
}
