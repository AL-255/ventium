// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tb_fxdiv.cpp — STANDALONE OOC testbench for the BEHAVIORAL x87 divide
// fpu_x87_pkg::fx_div (FDIV path of f_arith), bit-exact vs the SoftFloat-3e div
// golden. Combinational. Verifies the denormal-divide path whose board-fit stub
// (q = num>>7) was restored to the real 192-bit divide (q = num/mb) in 66a71c4.
//
// PROTOCOL: argv[1] = vectors file from gen_div_vectors.py, one per line:
//   <rc> <pc> <a80> <b80> <golden80> <xsw6>
// a80/b80/golden80 are 20 hex chars = signExp(4) || signif(16). GATE: the 80-bit
// DATA result must match golden80 exactly. {oe,ue,pe} (r[82:80]) are informational.
#include <verilated.h>
#include "Vfxdiv_dut.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

static void set80(EData* p, const char* s) {
    char se[5]; memcpy(se, s, 4); se[4] = 0;
    uint16_t se16 = (uint16_t)strtoul(se, nullptr, 16);
    uint64_t sig  = strtoull(s + 4, nullptr, 16);
    p[0] = (uint32_t)(sig & 0xFFFFFFFFu);
    p[1] = (uint32_t)(sig >> 32);
    p[2] = (uint32_t)se16;
}
// r is [82:0] -> VlWide<3>: r[0]=bits31:0, r[1]=bits63:32, r[2]=bits82:64.
// 80-bit result = bits79:0 (sig=bits63:0, se16=bits79:64); flags=bits82:80.
static void fmt_res(const EData* r, char* out, int* oe, int* ue, int* pe) {
    uint64_t sig  = ((uint64_t)r[1] << 32) | r[0];
    uint16_t se16 = (uint16_t)(r[2] & 0xFFFFu);
    unsigned fl   = (r[2] >> 16) & 0x7u;
    *pe = fl & 1; *ue = (fl >> 1) & 1; *oe = (fl >> 2) & 1;
    snprintf(out, 24, "%04x%016llx", (unsigned)se16, (unsigned long long)sig);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s <vectors.txt>\n", argv[0]); return 2; }
    FILE* f = fopen(argv[1], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    Vfxdiv_dut* dut = new Vfxdiv_dut;
    long total = 0, data_fail = 0, flag_fail = 0;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char a_s[32], b_s[32], g_s[32], gf_s[8]; int rc, pc;
        int n = sscanf(line, "%d %d %31s %31s %31s %7s", &rc, &pc, a_s, b_s, g_s, gf_s);
        if (n < 5) continue;
        unsigned gf = (n >= 6) ? (unsigned)strtoul(gf_s, nullptr, 16) : 0;
        int g_oe=(gf&1)?1:0, g_ue=(gf&2)?1:0, g_pe=(gf&4)?1:0;   // xsw flag layout (informational)

        set80(dut->a, a_s);
        set80(dut->b, b_s);
        dut->rc = (uint8_t)(rc & 3);
        dut->pc = (uint8_t)(pc & 3);
        dut->eval();

        char got[24]; int oe, ue, pe;
        fmt_res(dut->r, got, &oe, &ue, &pe);

        if (strcmp(got, g_s) != 0) {
            data_fail++;
            if (data_fail <= 60)
                printf("DATA MISMATCH rc=%d pc=%d a=%s b=%s got=%s want=%s\n", rc, pc, a_s, b_s, got, g_s);
        } else if (oe!=g_oe || ue!=g_ue || pe!=g_pe) {
            flag_fail++;
        }
        total++;
    }
    fclose(f);

    printf("\n=== x87 fx_div (behavioral FDIV) OOC gate ===\n");
    printf("vectors    : %ld\n", total);
    printf("data fails : %ld\n", data_fail);
    printf("flag deltas: %ld (informational)\n", flag_fail);
    printf("RESULT     : %s\n", data_fail == 0 ? "PASS bit-exact (fx_div)" : "FAIL");
    delete dut;
    return data_fail == 0 ? 0 : 1;
}
