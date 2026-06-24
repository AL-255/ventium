// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// =============================================================================
// tb_srt_div.cpp — STANDALONE out-of-context testbench for the iterative SRT
// divider (rtl/fpu/fpu_srt_div.sv), divide mode only.
//
// WHY THIS EXISTS: the full fpu87 gate Verilates the WHOLE core (memory-heavy,
// wedges resource-tight boxes) and — critically — builds the DEFAULT tb, i.e.
// the BIT-EXACT combinational divider, NOT the board's iterative SRT engine
// (which is only compiled under +define+VEN_SRT_ITER). So the existing gate
// never tested the divider that actually ships on the KV260. This harness
// instantiates ONLY fpu_srt_div + fpu_x87_pkg (a tiny, fast, low-memory
// Verilation) and checks its divide results bit-exact against the SoftFloat-3e
// extF80 oracle (verif/fpu87/oracle/ven_fpu_oracle.c). It is the lighter path
// for validating a91f3's denormal / gradual-underflow / overflow FDIV fix.
//
// PROTOCOL: argv[1] = vectors file, one test per line (produced by
// gen_div_vectors.py, golden from the oracle):
//     <rc> <a80> <b80> <golden80> <xsw6>
// where a80/b80/golden80 are 20 hex chars = signExp(4) || signif(16), rc is the
// x87 rounding control 0..3, xsw6 is the oracle's x87 status low-6 bits.
//
// GATE: the 80-bit DATA result must match golden80 exactly for every vector.
// The {oe,ue,pe} flags (result[82:80]) are compared INFORMATIONALLY against the
// oracle's OE/UE/PE bits (the RTL deliberately omits DE, and its ZE/flag mapping
// differs), so a flag delta is reported but does not fail the gate.
// =============================================================================
#include <verilated.h>
#include "Vfpu_srt_div.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>

static Vfpu_srt_div* dut;

// One posedge. tick() drives the comb settle (clk low) then the edge (clk high)
// and returns the combinational `done` strobe sampled after the edge.
static int tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    return dut->done;
}

// Set an 80-bit packed input port {signExp[15:0], signif[63:0]}.
static void set80(EData* p, uint16_t signExp, uint64_t signif) {
    p[0] = (uint32_t)(signif & 0xFFFFFFFFu);
    p[1] = (uint32_t)(signif >> 32);
    p[2] = (uint32_t)signExp;            // top word holds bits [79:64]
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s <vectors.txt> [div|sqrt]\n", argv[0]); return 2; }
    // mode: 0 = divide (a/b), 1 = square-root (sqrt(a); b ignored).
    int smode = (argc >= 3 && !strcmp(argv[2], "sqrt")) ? 1 : 0;
    const char* MODE_NAME = smode ? "sqrt" : "divide";
    FILE* f = fopen(argv[1], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    dut = new Vfpu_srt_div;

    // Reset.
    dut->rst_n = 0; dut->start = 0; dut->mode = 0; dut->prem1 = 0; dut->buggy = 0;
    dut->rc = 0;
    set80(dut->a, 0, 0); set80(dut->b, 0, 0);
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; tick();

    long total = 0, data_fail = 0, flag_fail = 0;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        int rc, pc; char a_s[32], b_s[32], g_s[32], x_s[8];
        int n = sscanf(line, "%d %d %31s %31s %31s %7s", &rc, &pc, a_s, b_s, g_s, x_s);
        if (n < 5) continue;

        char se4[5];
        memcpy(se4, a_s, 4); se4[4] = 0;
        uint16_t a_se = (uint16_t)strtoul(se4, nullptr, 16);
        uint64_t a_sig = strtoull(a_s + 4, nullptr, 16);
        memcpy(se4, b_s, 4); se4[4] = 0;
        uint16_t b_se = (uint16_t)strtoul(se4, nullptr, 16);
        uint64_t b_sig = strtoull(b_s + 4, nullptr, 16);

        // Drive one op (divide or sqrt).
        dut->mode = (uint8_t)smode; dut->prem1 = 0; dut->buggy = 0;
        dut->rc = (uint8_t)(rc & 3); dut->pc = (uint8_t)(pc & 3);
        set80(dut->a, a_se, a_sig);
        set80(dut->b, b_se, b_sig);
        dut->start = 1;
        int done = 0;
        for (int t = 0; t < 128 && !done; t++) { done = tick(); dut->start = 0; }
        if (!done) { fprintf(stderr, "TIMEOUT on vector %ld\n", total); data_fail++; total++; continue; }

        // result[82:0] = {oe, ue, pe, floatx80}.
        uint32_t r0 = dut->result[0], r1 = dut->result[1], r2 = dut->result[2];
        uint64_t got_sig = ((uint64_t)r1 << 32) | r0;
        uint16_t got_se  = (uint16_t)(r2 & 0xFFFF);
        int pe = (r2 >> 16) & 1, ue = (r2 >> 17) & 1, oe = (r2 >> 18) & 1;

        char got[32];
        snprintf(got, sizeof got, "%04x%016llx", got_se, (unsigned long long)got_sig);

        if (strcmp(got, g_s) != 0) {
            data_fail++;
            if (data_fail <= 40)
                printf("DATA  MISMATCH rc=%d pc=%d a=%s b=%s got=%s want=%s\n",
                       rc, pc, a_s, b_s, got, g_s);
        } else {
            // flags informational: oracle xsw bits PE=0x20 UE=0x10 OE=0x08
            unsigned xsw = (unsigned)strtoul(x_s, nullptr, 16);
            int wpe = (xsw & 0x20) ? 1 : 0, wue = (xsw & 0x10) ? 1 : 0, woe = (xsw & 0x08) ? 1 : 0;
            if (pe != wpe || ue != wue || oe != woe) {
                flag_fail++;
                if (flag_fail <= 20)
                    printf("flag  delta    rc=%d a=%s b=%s data=%s "
                           "rtl{oe%d ue%d pe%d} ora{oe%d ue%d pe%d}\n",
                           rc, a_s, b_s, got, oe, ue, pe, woe, wue, wpe);
            }
        }
        total++;
    }
    fclose(f);

    printf("\n=== SRT %s OOC gate ===\n", MODE_NAME);
    printf("vectors    : %ld\n", total);
    printf("data fails : %ld\n", data_fail);
    printf("flag deltas: %ld (informational)\n", flag_fail);
    printf("RESULT     : %s (%s)\n", data_fail == 0 ? "PASS bit-exact" : "FAIL", MODE_NAME);
    delete dut;
    return data_fail == 0 ? 0 : 1;
}
