// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// ven_bench.c — minimal benchmark runner for the live KV260 Ventium SoC.
//
// Boots a bare-metal -bios benchmark image in the DDR carveout, services its
// port-I/O (COM1 -> stdout, 0xF4 -> stop), and reports the exit reason. Unlike
// ven_soc_app it can toggle cycle_mode (dual-issue U/V) via --cycle, so a benchmark
// can be run single- vs dual-issue to exercise the pairing/forwarding datapaths.
//
//   ven_bench <img.bin> [--cycle]
//
// Build (cross): aarch64-linux-gnu-gcc -O2 -static -o ven_bench ven_bench.c

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>
#include "ven_soc_regs.h"

static volatile uint32_t *g_reg;
static volatile uint8_t  *g_ddr;
static inline uint32_t rd(uint32_t o)            { return g_reg[o >> 2]; }
static inline void     wr(uint32_t o, uint32_t v){ g_reg[o >> 2] = v; }
static uint64_t now_ms(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000+t.tv_nsec/1000000; }

int main(int argc, char **argv){
    const char *img = 0; int cyc = 0, i;
    for (i = 1; i < argc; i++){
        if      (!strcmp(argv[i], "--cycle")) cyc = 1;
        else if (!img) img = argv[i];
    }
    if (!img){ fprintf(stderr, "usage: %s <img.bin> [--cycle]\n", argv[0]); return 2; }
    const uint32_t load_off = 0xF0000, entry = 0x0, esp = 0x000FFFF0;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0){ perror("/dev/mem"); return 1; }
    g_reg = mmap(0, VEN_HPM0_SIZE,     PROT_READ|PROT_WRITE, MAP_SHARED, fd, VEN_HPM0_BASE);
    g_ddr = mmap(0, VEN_CARVEOUT_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, VEN_CARVEOUT_BASE);
    if (g_reg == MAP_FAILED || g_ddr == MAP_FAILED){ perror("mmap"); return 1; }
    if (rd(VEN_R_IDENT) != VEN_IDENT_MAGIC){ fprintf(stderr, "bad IDENT\n"); return 1; }

    wr(VEN_R_CTRL, 0);
    FILE *f = fopen(img, "rb"); if (!f){ perror(img); return 1; }
    size_t n = fread((void*)(g_ddr + load_off), 1, VEN_CARVEOUT_SIZE - load_off, f); fclose(f);
    __sync_synchronize();

    wr(VEN_R_INIT_EIP, entry);
    wr(VEN_R_INIT_ESP, esp);
    wr(VEN_R_MODE, VEN_MODE_L1AXI | VEN_MODE_COSIM | VEN_MODE_BOOT_SYS | (cyc ? VEN_MODE_CYCLE : 0));
    wr(VEN_R_CTRL, VEN_CTRL_CORE_RUN);
    fprintf(stderr, "ven_bench: %zu bytes staged, %s-issue, running\n", n, cyc ? "DUAL" : "single");

    uint64_t serviced = 0, t0 = now_ms();
    int rc = 1;
    for (;;){
        uint32_t st = rd(VEN_R_STATUS);
        if (st & VEN_ST_CPU_HUNG){ fprintf(stderr, "\nven_bench: CPU HUNG (bus_err=%d) after %llu io\n",
                                           !!(st & VEN_ST_BUS_ERR), (unsigned long long)serviced); rc = 4; break; }
        if (st & VEN_ST_IO_REQ){
            uint32_t ios = rd(VEN_R_IO_STATUS); uint16_t port = (uint16_t)rd(VEN_R_IO_ADDR);
            if (ios & VEN_IO_IS_WRITE){
                uint32_t v = rd(VEN_R_IO_WDATA);
                if (port == 0x3F8 || port == 0xE9){ putchar(v & 0xFF); fflush(stdout); }
                else if (port == 0xF4){ wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR);
                    fprintf(stderr, "\nven_bench: done after %llu io\n", (unsigned long long)serviced); rc = 0; break; }
            }
            wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR);
            serviced++;
        }
        if (now_ms() - t0 > 30000){ fprintf(stderr, "\nven_bench: timeout after %llu io\n", (unsigned long long)serviced); rc = 5; break; }
    }
    return rc;
}
