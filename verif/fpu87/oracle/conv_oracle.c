// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// conv_oracle — independent golden for the x87 float32/float64 <-> floatx80
// conversions (FLD/FST m32/m64), links Berkeley SoftFloat-3e (QEMU's softfloat).
// Used by the standalone OOC conversion gate (tb_conv.cpp).
//
// PROTOCOL (batch or single-shot): "<op> <rc> <in>"
//   op  : from32 (f32->x80) | from64 (f64->x80) | to32 (x80->f32) | to64 (x80->f64)
//   in  : from32 = 8 hex (f32 bits); from64 = 16 hex; to32/to64 = 20 hex (x80)
//   out : from* -> "<r80(20hex)> 0"      ; to* -> "<value(8/16 hex)> <flags>"
//         flags bit0=overflow bit1=underflow bit2=inexact
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "softfloat.h"

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
static unsigned flags(void) {
    unsigned f = 0, sf = (unsigned)softfloat_exceptionFlags;
    if (sf & softfloat_flag_overflow)  f |= 1;
    if (sf & softfloat_flag_underflow) f |= 2;
    if (sf & softfloat_flag_inexact)   f |= 4;
    return f;
}

static void do_one(const char* op, int rc, const char* in) {
    softfloat_roundingMode = (uint_fast8_t)rc_sf(rc);
    softfloat_exceptionFlags = 0;
    if (!strcmp(op, "from32")) {
        float32_t u; u.v = (uint32_t)strtoul(in, NULL, 16);
        extFloat80_t r = f32_to_extF80(u);
        printf("%04x%016llx 0\n", (unsigned)(r.signExp & 0xFFFF), (unsigned long long)r.signif);
    } else if (!strcmp(op, "from64")) {
        float64_t u; u.v = (uint64_t)strtoull(in, NULL, 16);
        extFloat80_t r = f64_to_extF80(u);
        printf("%04x%016llx 0\n", (unsigned)(r.signExp & 0xFFFF), (unsigned long long)r.signif);
    } else if (!strcmp(op, "to32")) {
        extFloat80_t a = parse80(in);
        float32_t r = extF80_to_f32(a);
        printf("%08x %x\n", (unsigned)r.v, flags());
    } else if (!strcmp(op, "to64")) {
        extFloat80_t a = parse80(in);
        float64_t r = extF80_to_f64(a);
        printf("%016llx %x\n", (unsigned long long)r.v, flags());
    } else {
        printf("0 0\n");
    }
}

int main(int argc, char** argv) {
    if (argc >= 4) { do_one(argv[1], atoi(argv[2]), argv[3]); return 0; }
    char line[256];
    while (fgets(line, sizeof line, stdin)) {
        char op[16], in[64]; int rc;
        if (sscanf(line, "%15s %d %63s", op, &rc, in) == 3) do_one(op, rc, in);
        else printf("0 0\n");
    }
    return 0;
}
