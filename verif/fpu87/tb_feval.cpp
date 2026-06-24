// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tb_feval.cpp — STANDALONE OOC testbench for the x87 add/sub/mul/subr evaluator
// (ventium_x87_pkg::f_eval and the board split f_eval_s2(f_eval_s1)). Gates the
// 80-bit result bit-exact vs the SoftFloat extF80 oracle, AND asserts the board
// split path == the full reference. Combinational — no clock.
//
// PROTOCOL: argv[1] = vectors file, one per line:
//   <sub> <rc> <a80> <b80> <golden80> <xsw6>
// where sub = 0 add / 1 mul / 4 sub / 5 subr; a80/b80/golden80 = 20 hex.
#include <verilated.h>
#include "Vfeval_dut.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

static void set80(EData* p, uint16_t signExp, uint64_t signif) {
    p[0] = (uint32_t)(signif & 0xFFFFFFFFu);
    p[1] = (uint32_t)(signif >> 32);
    p[2] = (uint32_t)signExp;
}
// result[79:0] of an 85-bit packed output: words [0],[1] + low 16 of [2].
static void res80(const EData* r, char* out) {
    uint64_t sig = ((uint64_t)r[1] << 32) | r[0];
    uint16_t se  = (uint16_t)(r[2] & 0xFFFF);
    snprintf(out, 24, "%04x%016llx", se, (unsigned long long)sig);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s <vectors.txt>\n", argv[0]); return 2; }
    FILE* f = fopen(argv[1], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    Vfeval_dut* dut = new Vfeval_dut;
    long total = 0, data_fail = 0, split_fail = 0;
    const char* OPN[8] = {"add","mul","?2","?3","sub","subr","div","divr"};
    char line[256];
    while (fgets(line, sizeof line, f)) {
        int sub, rc, pc; char a_s[32], b_s[32], g_s[32], x_s[8];
        int n = sscanf(line, "%d %d %d %31s %31s %31s %7s", &sub, &rc, &pc, a_s, b_s, g_s, x_s);
        if (n < 6) continue;

        char se4[5];
        memcpy(se4, a_s, 4); se4[4] = 0;
        uint16_t a_se = (uint16_t)strtoul(se4, nullptr, 16);
        uint64_t a_sig = strtoull(a_s + 4, nullptr, 16);
        memcpy(se4, b_s, 4); se4[4] = 0;
        uint16_t b_se = (uint16_t)strtoul(se4, nullptr, 16);
        uint64_t b_sig = strtoull(b_s + 4, nullptr, 16);

        dut->sub = (uint8_t)(sub & 7);
        dut->rc = (uint8_t)(rc & 3);
        dut->pc = (uint8_t)(pc & 3);
        dut->fdiv_err = 0;
        set80(dut->a, a_se, a_sig);
        set80(dut->b, b_se, b_sig);
        dut->eval();

        char full[24], split[24];
        res80(dut->r_full, full);
        res80(dut->r_split, split);

        if (strcmp(split, g_s) != 0) {
            data_fail++;
            if (data_fail <= 60)
                printf("DATA  MISMATCH %-4s rc=%d pc=%d a=%s b=%s split=%s want=%s (full=%s)\n",
                       OPN[sub & 7], rc, pc, a_s, b_s, split, g_s, full);
        }
        if (strcmp(full, split) != 0) {
            split_fail++;
            if (split_fail <= 30)
                printf("SPLIT!=FULL    %-4s rc=%d a=%s b=%s full=%s split=%s\n",
                       OPN[sub & 7], rc, a_s, b_s, full, split);
        }
        total++;
    }
    fclose(f);

    printf("\n=== x87 f_eval (add/sub/mul) OOC gate ===\n");
    printf("vectors        : %ld\n", total);
    printf("data fails     : %ld (board split vs SoftFloat)\n", data_fail);
    printf("split!=full    : %ld\n", split_fail);
    printf("RESULT         : %s\n",
           (data_fail == 0 && split_fail == 0) ? "PASS (bit-exact add/sub/mul)" : "FAIL");
    delete dut;
    return (data_fail == 0 && split_fail == 0) ? 0 : 1;
}
