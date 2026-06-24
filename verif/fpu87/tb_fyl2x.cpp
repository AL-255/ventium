// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tb_fyl2x.cpp — STANDALONE OOC testbench for the x87 FYL2X transcendental
// (rtl/fpu/fpu_fyl2x.sv, mode=0 = y*log2(x)), compared vs the qref P5
// transcendental oracle. FYL2X is the one KNOWN-non-bit-exact family; this gate
// QUANTIFIES the divergence (how many vectors, and by how many ULPs) to decide
// whether it could plausibly flip a Quake loop bound (1-ULP: no; large: maybe).
//
// PROTOCOL: argv[1] = vectors file: <rc> <y80> <x80> <gold80>
#include <verilated.h>
#include "Vfpu_fyl2x.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cmath>

static Vfpu_fyl2x* dut;
static void set80(EData* p, const char* s) {
    char se[5]; memcpy(se, s, 4); se[4] = 0;
    p[0] = (uint32_t)(strtoull(s + 4, nullptr, 16) & 0xFFFFFFFFu);
    p[1] = (uint32_t)(strtoull(s + 4, nullptr, 16) >> 32);
    p[2] = (uint32_t)strtoul(se, nullptr, 16);
}
static int tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); return dut->done; }

// crude ULP-ish distance: |significand delta| when exps equal, else large.
static long ulp_delta(const char* a, const char* b) {
    uint64_t ase = strtoul(std::string(a, a + 4).c_str(), nullptr, 16) & 0x7fff;
    uint64_t bse = strtoul(std::string(b, b + 4).c_str(), nullptr, 16) & 0x7fff;
    uint64_t am = strtoull(a + 4, nullptr, 16), bm = strtoull(b + 4, nullptr, 16);
    if (ase != bse) return -1;                  // different exponent: not a small-ULP diff
    return (long)(am > bm ? am - bm : bm - am);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s <vectors.txt>\n", argv[0]); return 2; }
    FILE* f = fopen(argv[1], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    dut = new Vfpu_fyl2x;
    dut->rst_n = 0; dut->start = 0; dut->mode = 0; dut->rc = 0;
    set80(dut->x, "3fff8000000000000000"); set80(dut->y, "3fff8000000000000000");
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; tick();

    long total = 0, fails = 0, ulp1 = 0, ulp_big = 0, exp_diff = 0; long maxulp = 0;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        int rc; char y_s[32], x_s[32], g_s[32];
        if (sscanf(line, "%d %31s %31s %31s", &rc, y_s, x_s, g_s) < 4) continue;
        dut->mode = 0; dut->rc = (uint8_t)(rc & 3);
        set80(dut->y, y_s); set80(dut->x, x_s);
        dut->start = 1; int done = 0;
        for (int t = 0; t < 4096 && !done; t++) { done = tick(); dut->start = 0; }
        if (!done) { fprintf(stderr, "TIMEOUT vec %ld\n", total); fails++; total++; continue; }
        uint64_t sig = ((uint64_t)dut->result[1] << 32) | dut->result[0];
        char got[24]; snprintf(got, sizeof got, "%04x%016llx",
                               (unsigned)(dut->result[2] & 0xFFFF), (unsigned long long)sig);
        if (strcmp(got, g_s) != 0) {
            fails++;
            long d = ulp_delta(got, g_s);
            if (d < 0) exp_diff++;
            else if (d <= 1) ulp1++;
            else { ulp_big++; if (d > maxulp) maxulp = d; }
            if (fails <= 25)
                printf("FYL2X DIFF rc=%d y=%s x=%s got=%s want=%s ulp=%ld\n", rc, y_s, x_s, got, g_s, d);
        }
        total++;
    }
    fclose(f);
    printf("\n=== x87 FYL2X OOC characterization (vs qref) ===\n");
    printf("vectors      : %ld\n", total);
    printf("diffs        : %ld (%.2f%%)\n", fails, total ? 100.0 * fails / total : 0.0);
    printf("  <=1 ULP    : %ld\n", ulp1);
    printf("  >1 ULP     : %ld (max %ld)\n", ulp_big, maxulp);
    printf("  exp differ : %ld\n", exp_diff);
    printf("NOTE: FYL2X is area-optimized; small-ULP diffs are expected. Large/exp diffs matter.\n");
    delete dut;
    return 0;   // characterization, not pass/fail
}
