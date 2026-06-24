// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tb_fist.cpp — STANDALONE OOC testbench for the x87 FIST/FISTP conversion
// (fpu_x87_pkg::fx_to_int_ex via fist_dut.sv), checked bit-exact vs the
// SoftFloat-3e fist golden (fist_oracle). This is the pinned board-F5 suspect:
// the DOS-Quake live loop diverged at a fist (cs=00a7:0x3079a, Ventium 0x67 vs
// qemu 0x65). If this gate PASSES, the fist itself is exonerated and the
// divergence is upstream (the x87 math feeding it); if it FAILS, the mismatch
// lines pinpoint the exact (value,width,rc) that misconverts.
//
// fx_to_int_ex is COMBINATIONAL — no clock. PROTOCOL: argv[1] = vectors file,
//   <width> <rc> <v80> <goldval16hex> <gflags>
// gate on {invalid, value}; inexact is informational.
#include <verilated.h>
#include "Vfist_dut.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

static void set80(EData* p, uint16_t signExp, uint64_t signif) {
    p[0] = (uint32_t)(signif & 0xFFFFFFFFu);
    p[1] = (uint32_t)(signif >> 32);
    p[2] = (uint32_t)signExp;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s <vectors.txt>\n", argv[0]); return 2; }
    FILE* f = fopen(argv[1], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    Vfist_dut* dut = new Vfist_dut;
    long total = 0, data_fail = 0, inex_fail = 0;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        int width, rc; char v_s[32], g_s[32], gf_s[8];
        int n = sscanf(line, "%d %d %31s %31s %7s", &width, &rc, v_s, g_s, gf_s);
        if (n < 4) continue;

        char se4[5]; memcpy(se4, v_s, 4); se4[4] = 0;
        uint16_t v_se = (uint16_t)strtoul(se4, nullptr, 16);
        uint64_t v_sig = strtoull(v_s + 4, nullptr, 16);
        uint64_t gold = strtoull(g_s, nullptr, 16);
        unsigned gf = (n >= 5) ? (unsigned)strtoul(gf_s, nullptr, 16) : 0;
        int g_invalid = (gf & 1) ? 1 : 0, g_inexact = (gf & 2) ? 1 : 0;

        set80(dut->v, v_se, v_sig);
        dut->width = (uint8_t)width;
        dut->rc = (uint8_t)(rc & 3);
        dut->eval();

        uint32_t r0 = dut->r[0], r1 = dut->r[1], r2 = dut->r[2];
        uint64_t val = ((uint64_t)r1 << 32) | r0;
        int inexact = r2 & 1, invalid = (r2 >> 1) & 1;

        if (val != gold || invalid != g_invalid) {
            data_fail++;
            if (data_fail <= 100000)
                printf("DATA MISMATCH w=%d rc=%d v=%s got=%016llx(inv%d) want=%016llx(inv%d)\n",
                       width, rc, v_s, (unsigned long long)val, invalid,
                       (unsigned long long)gold, g_invalid);
        } else if (inexact != g_inexact) {
            inex_fail++;
            if (inex_fail <= 20)
                printf("inexact delta w=%d rc=%d v=%s val=%016llx rtl%d ora%d\n",
                       width, rc, v_s, (unsigned long long)val, inexact, g_inexact);
        }
        total++;
    }
    fclose(f);

    printf("\n=== x87 FIST (fx_to_int_ex) OOC gate ===\n");
    printf("vectors      : %ld\n", total);
    printf("data fails   : %ld\n", data_fail);
    printf("inexact delta: %ld (informational)\n", inex_fail);
    printf("RESULT       : %s\n", data_fail == 0 ? "PASS (bit-exact fist)" : "FAIL");
    delete dut;
    return data_fail == 0 ? 0 : 1;
}
