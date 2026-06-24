// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tb_conv.cpp — STANDALONE OOC testbench for the x87 float32/float64 <-> floatx80
// conversions (fx_from_f32/f64, fx_to_f32_ex/f64_ex), bit-exact vs the SoftFloat
// conv golden (conv_oracle). Combinational — no clock. Quake constantly FLD/FST
// 32-bit floats, so a narrowing-store rounding bug here would corrupt loaded /
// stored values and is a candidate for the upstream fist-input divergence.
//
// PROTOCOL: argv[1] = vectors file, one per line:
//   <op> <rc> <in> <gold> <gflags>
//   op = from32|from64|to32|to64 ; gates on the data value, flags informational.
#include <verilated.h>
#include "Vconv_dut.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

static void set80(EData* p, const char* s) {
    char se[5]; memcpy(se, s, 4); se[4] = 0;
    uint16_t se16 = (uint16_t)strtoul(se, nullptr, 16);
    uint64_t sig = strtoull(s + 4, nullptr, 16);
    p[0] = (uint32_t)(sig & 0xFFFFFFFFu);
    p[1] = (uint32_t)(sig >> 32);
    p[2] = (uint32_t)se16;
}
static void fmt80(const EData* r, char* out) {
    uint64_t sig = ((uint64_t)r[1] << 32) | r[0];
    snprintf(out, 24, "%04x%016llx", (unsigned)(r[2] & 0xFFFF), (unsigned long long)sig);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s <vectors.txt>\n", argv[0]); return 2; }
    FILE* f = fopen(argv[1], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    Vconv_dut* dut = new Vconv_dut;
    long total = 0, data_fail = 0, flag_fail = 0;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char op[16], in_s[32], g_s[32], gf_s[8]; int rc;
        int n = sscanf(line, "%15s %d %31s %31s %7s", op, &rc, in_s, g_s, gf_s);
        if (n < 4) continue;
        unsigned gf = (n >= 5) ? (unsigned)strtoul(gf_s, nullptr, 16) : 0;

        // drive all inputs (only the op's output is read)
        dut->u32 = (uint32_t)strtoul(in_s, nullptr, 16);
        dut->u64 = (uint64_t)strtoull(in_s, nullptr, 16);
        if (strlen(in_s) >= 20) set80(dut->v, in_s); else { dut->v[0]=dut->v[1]=dut->v[2]=0; }
        dut->rc = (uint8_t)(rc & 3);
        dut->eval();

        char got[24]; int g_oe=(gf&1)?1:0, g_ue=(gf&2)?1:0, g_pe=(gf&4)?1:0;
        int oe=0, ue=0, pe=0; bool is_to=false;
        if (!strcmp(op, "from32"))      fmt80(dut->o_from32, got);
        else if (!strcmp(op, "from64")) fmt80(dut->o_from64, got);
        else if (!strcmp(op, "to32")) {
            uint64_t r = dut->o_to32;                       // 35-bit -> QData
            snprintf(got, sizeof got, "%08x", (unsigned)(r & 0xFFFFFFFFu));
            pe=(r>>32)&1; ue=(r>>33)&1; oe=(r>>34)&1; is_to=true;
        } else { // to64
            const EData* r = dut->o_to64;                   // 67-bit -> VlWide<3>
            uint64_t v = ((uint64_t)r[1] << 32) | r[0];
            snprintf(got, sizeof got, "%016llx", (unsigned long long)v);
            pe=r[2]&1; ue=(r[2]>>1)&1; oe=(r[2]>>2)&1; is_to=true;
        }

        if (strcmp(got, g_s) != 0) {
            data_fail++;
            if (data_fail <= 60)
                printf("DATA MISMATCH %-6s rc=%d in=%s got=%s want=%s\n", op, rc, in_s, got, g_s);
        } else if (is_to && (oe!=g_oe || ue!=g_ue || pe!=g_pe)) {
            flag_fail++;
            if (flag_fail <= 30)
                printf("flag delta   %-6s rc=%d in=%s val=%s rtl{o%d u%d p%d} ora{o%d u%d p%d}\n",
                       op, rc, in_s, got, oe, ue, pe, g_oe, g_ue, g_pe);
        }
        total++;
    }
    fclose(f);

    printf("\n=== x87 f32/f64 conversion OOC gate ===\n");
    printf("vectors    : %ld\n", total);
    printf("data fails : %ld\n", data_fail);
    printf("flag deltas: %ld (informational)\n", flag_fail);
    printf("RESULT     : %s\n", data_fail == 0 ? "PASS (bit-exact conv)" : "FAIL");
    delete dut;
    return data_fail == 0 ? 0 : 1;
}
