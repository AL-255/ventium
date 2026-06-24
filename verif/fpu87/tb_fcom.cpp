// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tb_fcom.cpp — STANDALONE OOC testbench for the x87 FCOM condition codes
// (ventium_x87_pkg::fcom_codes), checked vs an independent floatx80 rational
// compare (gen_fcom_vectors.py). Combinational. PROTOCOL: argv[1] = vectors file
//   <a80> <b80> <gold_codes>      gold_codes = (C3<<2)|(C2<<1)|C0
#include <verilated.h>
#include "Vfcom_dut.h"
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

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s <vectors.txt>\n", argv[0]); return 2; }
    FILE* f = fopen(argv[1], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    Vfcom_dut* dut = new Vfcom_dut;
    long total = 0, fail = 0;
    const char* NM[8] = {"GT","LT","?2","?3","EQ","?5","?6","UNORD"};
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char a_s[32], b_s[32]; int gold;
        int n = sscanf(line, "%31s %31s %d", a_s, b_s, &gold);
        if (n < 3) continue;
        set80(dut->a, a_s);
        set80(dut->b, b_s);
        dut->eval();
        int got = dut->codes & 7;
        if (got != gold) {
            fail++;
            if (fail <= 60)
                printf("FCOM MISMATCH a=%s b=%s got=%d(%s) want=%d(%s)\n",
                       a_s, b_s, got, NM[got], gold, NM[gold]);
        }
        total++;
    }
    fclose(f);
    printf("\n=== x87 FCOM condition-code OOC gate ===\n");
    printf("vectors : %ld\n", total);
    printf("fails   : %ld\n", fail);
    printf("RESULT  : %s\n", fail == 0 ? "PASS (codes match)" : "FAIL");
    delete dut;
    return fail == 0 ? 0 : 1;
}
