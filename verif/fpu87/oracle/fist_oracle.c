// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// fist_oracle — independent x87 FIST/FISTP (floatx80 -> signed integer) golden
// for the standalone OOC fist gate (tb_fist.cpp). Links Berkeley SoftFloat-3e
// (the same library + 8086-SSE specialization the main fpu87 oracle uses, which
// is QEMU's softfloat behaviour), so it is the authoritative reference for
// whether rtl/fpu/fpu_x87_pkg.sv::fx_to_int_ex is bit-exact vs QEMU.
//
// Mirrors QEMU's helper_fist*: convert with the active rounding mode; on
// out-of-range / NaN / Inf write the width's integer-indefinite (min signed
// value) and raise invalid; width 16 converts via int32 then range-checks.
//
// PROTOCOL (batch or single-shot):
//   stdin/argv : "<width> <rc> <a80>"   width in {16,32,64}; rc 0..3; a80 = 20 hex
//   stdout     : "<value16hex> <flags>" flags bit0=invalid bit1=inexact
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "softfloat.h"

enum { F_INVALID = 1, F_INEXACT = 2 };

static extFloat80_t parse80(const char* s) {
    char se[5]; memcpy(se, s, 4); se[4] = 0;
    extFloat80_t x;
    x.signExp = (uint16_t)strtoul(se, NULL, 16);
    x.signif  = (uint64_t)strtoull(s + 4, NULL, 16);
    return x;
}
static int rc_sf(int rc) {
    switch (rc & 3) {
        case 0:  return softfloat_round_near_even;
        case 1:  return softfloat_round_min;
        case 2:  return softfloat_round_max;
        default: return softfloat_round_minMag;
    }
}

static void do_one(int width, int rc, const char* a_s) {
    extFloat80_t a = parse80(a_s);
    uint_fast8_t rm = (uint_fast8_t)rc_sf(rc);
    uint64_t indef = (width == 16) ? 0x8000ull :
                     (width == 32) ? 0x80000000ull : 0x8000000000000000ull;
    uint64_t outval; unsigned fl = 0;

    softfloat_exceptionFlags = 0;
    if (width == 64) {
        int_fast64_t r = extF80_to_i64(a, rm, true);
        if (softfloat_exceptionFlags & softfloat_flag_invalid) { outval = indef; fl = F_INVALID; }
        else { outval = (uint64_t)r;
               if (softfloat_exceptionFlags & softfloat_flag_inexact) fl |= F_INEXACT; }
    } else {
        int_fast32_t r = extF80_to_i32(a, rm, true);
        int inv = (softfloat_exceptionFlags & softfloat_flag_invalid) != 0;
        if (width == 16) {
            if (inv || r > 32767 || r < -32768) { outval = indef; fl = F_INVALID; }
            else { outval = (uint64_t)(int64_t)r;
                   if (softfloat_exceptionFlags & softfloat_flag_inexact) fl |= F_INEXACT; }
        } else {
            if (inv) { outval = indef; fl = F_INVALID; }
            else { outval = (uint64_t)(int64_t)r;
                   if (softfloat_exceptionFlags & softfloat_flag_inexact) fl |= F_INEXACT; }
        }
    }
    printf("%016llx %x\n", (unsigned long long)outval, fl);
}

int main(int argc, char** argv) {
    if (argc >= 4) { do_one(atoi(argv[1]), atoi(argv[2]), argv[3]); return 0; }
    char line[256];
    while (fgets(line, sizeof line, stdin)) {
        int width, rc; char a[64];
        if (sscanf(line, "%d %d %63s", &width, &rc, a) == 3) do_one(width, rc, a);
        else printf("0000000000000000 0\n");
    }
    return 0;
}
