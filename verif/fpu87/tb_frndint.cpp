// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tb_frndint.cpp — STANDALONE OOC testbench for x87 FRNDINT (frndint_dut),
// bit-exact vs the SoftFloat round-to-int golden (ven_fpu_oracle `rndint`).
// Combinational. PROTOCOL: argv[1] = vectors file
//   <rc> <v80> <gold80> <xsw6>
// gate on the 80-bit result; PE informational.
#include <verilated.h>
#include "Vfrndint_dut.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

static void set80(EData* p, const char* s) {
    char se[5]; memcpy(se, s, 4); se[4] = 0;
    p[0] = (uint32_t)(strtoull(s + 4, nullptr, 16) & 0xFFFFFFFFu);
    p[1] = (uint32_t)(strtoull(s + 4, nullptr, 16) >> 32);
    p[2] = (uint32_t)strtoul(se, nullptr, 16);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s <vectors.txt>\n", argv[0]); return 2; }
    FILE* f = fopen(argv[1], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    Vfrndint_dut* dut = new Vfrndint_dut;
    long total = 0, data_fail = 0, pe_fail = 0;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        int rc; char v_s[32], g_s[32], x_s[8];
        int n = sscanf(line, "%d %31s %31s %7s", &rc, v_s, g_s, x_s);
        if (n < 3) continue;
        unsigned xsw = (n >= 4) ? (unsigned)strtoul(x_s, nullptr, 16) : 0;
        int g_pe = (xsw & 0x20) ? 1 : 0;

        set80(dut->v, v_s);
        dut->rc = (uint8_t)(rc & 3);
        dut->eval();

        uint64_t sig = ((uint64_t)dut->r[1] << 32) | dut->r[0];
        char got[24];
        snprintf(got, sizeof got, "%04x%016llx", (unsigned)(dut->r[2] & 0xFFFF), (unsigned long long)sig);

        if (strcmp(got, g_s) != 0) {
            data_fail++;
            if (data_fail <= 50)
                printf("FRNDINT MISMATCH rc=%d v=%s got=%s want=%s\n", rc, v_s, got, g_s);
        } else if ((int)dut->pe != g_pe) {
            pe_fail++;
        }
        total++;
    }
    fclose(f);
    printf("\n=== x87 FRNDINT OOC gate ===\n");
    printf("vectors    : %ld\n", total);
    printf("data fails : %ld\n", data_fail);
    printf("pe deltas  : %ld (informational)\n", pe_fail);
    printf("RESULT     : %s\n", data_fail == 0 ? "PASS (bit-exact frndint)" : "FAIL");
    delete dut;
    return data_fail == 0 ? 0 : 1;
}
