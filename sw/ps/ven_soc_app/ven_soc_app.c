// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/ven_soc_app.c — F2 PS-side bring-up app for the KV260 Ventium SoC.
//
// Runs on the A53 (PetaLinux userspace). It is the real-HW analogue of the cosim's
// tb_main.cpp: it loads a program image into the reserved DDR carveout, drives the
// ven_soc_axil control slave to boot the core, then services the port-I/O bridge —
// emulating slow peripherals in software (here: a console UART + the isa-debug-exit
// port). The core runs in PL at speed; every IN/OUT stalls the core until this loop
// answers, so device latency is correctness-safe (the core parks in S_IO).
//
// F2 scope: boot + console output + clean exit. F3 (FreeDOS) adds PIT/PIC/IDE/keyboard
// device models + interrupt injection; F4 (Quake) adds the int-0x80 proxy + framebuffer.
//
// Build (PetaLinux/aarch64): make ; run as root (needs /dev/mem):  ./ven_soc_app prog.bin
//
// NOTE: untested on hardware — there is no board in the dev loop yet. The register
// protocol is the one the Verilator unit gate (run-soc-axil-gate.sh) proves.

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include "ven_soc_regs.h"

static volatile uint32_t *g_reg;     // mmap'd AXI-Lite slave
static volatile uint8_t  *g_ddr;     // mmap'd DDR carveout

static inline uint32_t rd(uint32_t off)          { return g_reg[off >> 2]; }
static inline void     wr(uint32_t off, uint32_t v) { g_reg[off >> 2] = v; }

// --- console / device emulation (the part that grows for F3/F4) --------------
// F2: a tiny UART. OUT to 0x3F8 (COM1 THR) or 0xE9 (debug) -> stdout. IN from the
// COM1 LSR (0x3FD) returns "THR empty, data ready" so a UART-poll loop proceeds.
static int service_out(uint16_t port, uint32_t val) {
    switch (port) {
        case 0x00E9:                       // bochs/qemu debug console
        case 0x03F8: putchar((int)(val & 0xFF)); fflush(stdout); return 0;
        case 0x00F4: return 1;             // isa-debug-exit -> stop the run
        default:     return 0;             // ignore unmodeled OUTs (F3 fills these in)
    }
}
static uint32_t service_in(uint16_t port, uint8_t size) {
    (void)size;
    switch (port) {
        case 0x03FD: return 0x60;          // COM1 LSR: THR-empty | TSR-empty
        case 0x03F8: return 0x00;          // COM1 RBR: no input byte
        default:     return 0xFF;          // unmodeled IN -> all-ones (F3 fills these in)
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <program.bin> [load_off] [entry] [esp] [--sys]\n", argv[0]); return 2; }
    const char *img = argv[1];
    uint32_t load_off = (argc > 2) ? strtoul(argv[2], 0, 0) : 0x0;
    uint32_t entry    = (argc > 3) ? strtoul(argv[3], 0, 0) : 0x0;
    uint32_t esp      = (argc > 4) ? strtoul(argv[4], 0, 0) : 0x000FFFF0;
    int      sysmode  = (argc > 5 && !strcmp(argv[5], "--sys"));

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    g_reg = mmap(0, VEN_HPM0_SIZE,     PROT_READ|PROT_WRITE, MAP_SHARED, fd, VEN_HPM0_BASE);
    g_ddr = mmap(0, VEN_CARVEOUT_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, VEN_CARVEOUT_BASE);
    if (g_reg == MAP_FAILED || g_ddr == MAP_FAILED) { perror("mmap"); return 1; }

    uint32_t ident = rd(VEN_R_IDENT);
    if (ident != VEN_IDENT_MAGIC) { fprintf(stderr, "bad IDENT 0x%08x (slave not present?)\n", ident); return 1; }

    // hold the core in reset (CORE_RUN=0 by default at slave reset), stage the image.
    wr(VEN_R_CTRL, 0);                                   // ensure CORE_RUN=0
    FILE *f = fopen(img, "rb");
    if (!f) { perror(img); return 1; }
    size_t n = fread((void *)(g_ddr + load_off), 1, VEN_CARVEOUT_SIZE - load_off, f);
    fclose(f);
    __sync_synchronize();                                // flush the image to DRAM before run
    fprintf(stderr, "ven_soc: loaded %zu bytes at carveout+0x%x; entry=0x%x esp=0x%x %s\n",
            n, load_off, entry, esp, sysmode ? "[system]" : "[user]");

    // boot config: route memory via L1/AXI (mode 2) + IN/OUT via the io bridge.
    wr(VEN_R_INIT_EIP, entry);
    wr(VEN_R_INIT_ESP, esp);
    wr(VEN_R_MODE, VEN_MODE_L1AXI | VEN_MODE_COSIM | (sysmode ? VEN_MODE_BOOT_SYS : 0));
    wr(VEN_R_CTRL, VEN_CTRL_CORE_RUN);                   // release reset -> run

    // service loop (F2: poll; F3+ can switch to the GIC interrupt on irq_out).
    uint64_t serviced = 0;
    for (;;) {
        uint32_t st = rd(VEN_R_STATUS);
        if (st & VEN_ST_CPU_HUNG) { fprintf(stderr, "\nven_soc: CPU HUNG (bus_err=%d) after %llu io\n",
                                            !!(st & VEN_ST_BUS_ERR), (unsigned long long)serviced); break; }
        if (st & VEN_ST_IO_REQ) {
            uint32_t ios  = rd(VEN_R_IO_STATUS);
            uint16_t port = (uint16_t)rd(VEN_R_IO_ADDR);
            if (ios & VEN_IO_IS_WRITE) {
                uint32_t v = rd(VEN_R_IO_WDATA);
                if (service_out(port, v)) {              // out 0xf4 -> done
                    wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR);
                    fprintf(stderr, "\nven_soc: isa-debug-exit after %llu io\n", (unsigned long long)serviced);
                    break;
                }
            } else {
                wr(VEN_R_IO_RDATA, service_in(port, (uint8_t)rd(VEN_R_IO_SIZE)));
            }
            wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR);   // release the stalled core
            serviced++;
        }
        // (no busy-spin throttle here; F3 sleeps on the GIC irq via UIO instead.)
    }
    return 0;
}
