// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// test_quake_glue.c — HOST unit check for the F4 board glue (ven_quake.* +
// mem_carveout.cpp + the ported emulator/loader). It mallocs a 256 MiB stand-in
// for the DDR carveout, stages the real captured Quake image into it via
// ven_quake_init(), and drives a few int-0x80s the way the board service loop
// would — confirming: image regs parse (eip/esp), the g_ddr-backed MemModel
// round-trips, set_thread_area returns apply_gs + a TLS base, brk grows, and the
// time syscall writes the carveout. This is the off-board half of the proxy path
// (the on-board half adds the RTL window + the real core). Prints GLUE-OK/-FAIL.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ven_quake.h"

// i386 NRs the harness drives.
enum { NR_set_thread_area = 243, NR_brk = 45, NR_gettimeofday = 78 };

static int errors = 0;
static void chk(const char* what, long long got, long long exp) {
    if (got != exp) { printf("  FAIL %-28s got 0x%llx exp 0x%llx\n", what,
                             (unsigned long long)got, (unsigned long long)exp); errors++; }
    else            printf("  ok   %-28s = 0x%llx\n", what, (unsigned long long)got);
}

int main(int argc, char** argv) {
    const char* image = (argc > 1) ? argv[1] : "../../../build/quake-fb/image.json";
    const uint32_t MASK = 0x0FFFFFFFu;                  // 256 MiB carveout fold
    uint8_t* ddr = (uint8_t*)calloc(1, (size_t)MASK + 1);
    if (!ddr) { printf("GLUE-FAIL (calloc 256MiB)\n"); return 1; }

    uint32_t eip = 0, esp = 0;
    if (ven_quake_init(ddr, MASK, image, "/p5q_video_capture", 0x0a000000u, &eip, &esp) != 0) {
        printf("GLUE-FAIL (image '%s' load)\n", image); return 1;
    }
    printf("[1] image regs\n");
    chk("entry eip", eip, 0x08049237);
    chk("init  esp", esp, 0x40c34860);
    // a known materialised byte: eip points into the loaded text — non-zero opcode.
    chk("text byte @eip non-zero", ddr[eip & MASK] != 0, 1);

    printf("[2] set_thread_area -> %%gs TLS base (the #1 footgun)\n");
    // user_desc @ a scratch guest addr: entry_number=-1 (allocate), base_addr=BASE.
    const uint32_t ud = 0x00200000u, BASE = 0xCAFE1000u;
    ddr[(ud + 0) & MASK] = 0xff; ddr[(ud + 1) & MASK] = 0xff;     // entry = 0xffffffff
    ddr[(ud + 2) & MASK] = 0xff; ddr[(ud + 3) & MASK] = 0xff;
    ddr[(ud + 4) & MASK] = (uint8_t)BASE;        ddr[(ud + 5) & MASK] = (uint8_t)(BASE >> 8);
    ddr[(ud + 6) & MASK] = (uint8_t)(BASE >> 16);ddr[(ud + 7) & MASK] = (uint8_t)(BASE >> 24);
    struct ven_sys_result r;
    ven_quake_service(NR_set_thread_area, ud, 0, 0, 0, 0, 0, 0, &r);
    chk("set_thread_area eax", r.eax, 0);
    chk("apply_gs", r.apply_gs, 1);
    chk("gs_base", r.gs_base, BASE);
    // the emulator must have written the allocated entry number (6) back at ud.
    uint32_t entry = ddr[ud & MASK] | (ddr[(ud+1)&MASK]<<8) | (ddr[(ud+2)&MASK]<<16) | ((uint32_t)ddr[(ud+3)&MASK]<<24);
    chk("entry written back (6)", entry, 6);

    printf("[3] brk grows + queries\n");
    ven_quake_service(NR_brk, 0, 0, 0, 0, 0, 0, 0, &r);
    uint32_t brk0 = r.eax;
    chk("brk(0) == page_up(0x0a000000)", brk0, 0x0a000000);
    ven_quake_service(NR_brk, brk0 + 0x4000, 0, 0, 0, 0, 0, 0, &r);
    chk("brk grow", r.eax, brk0 + 0x4000);

    printf("[4] gettimeofday writes the carveout\n");
    const uint32_t tv = 0x00210000u;
    ven_quake_service(NR_gettimeofday, tv, 0, 0, 0, 0, 0, 1000 /*cycles*/, &r);
    chk("gettimeofday eax", r.eax, 0);
    uint32_t tsec = ddr[tv & MASK] | (ddr[(tv+1)&MASK]<<8) | (ddr[(tv+2)&MASK]<<16) | ((uint32_t)ddr[(tv+3)&MASK]<<24);
    chk("tv_sec advanced (>=1)", tsec >= 1, 1);

    free(ddr);
    if (errors == 0) printf("GLUE-OK (%llu syscalls serviced)\n", (unsigned long long)ven_quake_syscalls());
    else             printf("GLUE-FAIL (%d errors)\n", errors);
    return errors ? 1 : 0;
}
