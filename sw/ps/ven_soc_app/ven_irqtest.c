// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// ven_irqtest.c — M-A live-board interrupt-injection smoke for the KV260 Ventium SoC.
//
// The cheapest make-or-break hardware gate on the road to FreeDOS-on-board: it proves
// the deployed bitstream honours cosim_en (IO bridge) AND soc_en (external-INTR divert)
// at the same time, and that the PS R_INTR injection + INTA-seen handshake actually
// delivers a real-mode interrupt through the guest IVT on real silicon — BEFORE any
// peripheral C model is written. If this fails there is no software fallback (the seam
// is in the PL), so it runs first and costs almost nothing.
//
// It stages the mairq.bin guest (prints 'A', then a 'T' per delivered IRQ0, isa-debug-
// exits after 16), boots the core in --sys mode with SOCEN, services its I/O, and
// injects vector 8 on a cadence using the exact handshake the F3 pump uses.
//
// Build (on the board): gcc -O2 -static -o ven_irqtest ven_irqtest.c
// Run (root):           ./ven_irqtest mairq.bin
//
// Expected: "A" then "TTTTTTTTTTTTTTTT", then "isa-debug-exit"; exit 0. A CPU_HUNG /
// BUS_ERR / timeout is a FAIL (the seam or the cosim/soc combo does not work on silicon).

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

static uint64_t now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int main(int argc, char **argv) {
    const char *img = argc > 1 ? argv[1] : "mairq.bin";
    const uint32_t load_off = 0xF0000, entry = 0x0, esp = 0x000FFFF0;
    const uint64_t INJECT_MS = 50;          // inject one IRQ0 every 50 ms (~20 Hz)
    const uint64_t TIMEOUT_MS = 15000;       // whole test must finish in 15 s

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    g_reg = mmap(0, VEN_HPM0_SIZE,     PROT_READ|PROT_WRITE, MAP_SHARED, fd, VEN_HPM0_BASE);
    g_ddr = mmap(0, VEN_CARVEOUT_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, VEN_CARVEOUT_BASE);
    if (g_reg == MAP_FAILED || g_ddr == MAP_FAILED) { perror("mmap"); return 1; }

    uint32_t ident = rd(VEN_R_IDENT);
    if (ident != VEN_IDENT_MAGIC) { fprintf(stderr, "bad IDENT 0x%08x\n", ident); return 1; }

    wr(VEN_R_CTRL, 0);                      // hold core in reset
    FILE *f = fopen(img, "rb");
    if (!f) { perror(img); return 1; }
    size_t n = fread((void *)(g_ddr + load_off), 1, VEN_CARVEOUT_SIZE - load_off, f);
    fclose(f);
    __sync_synchronize();
    fprintf(stderr, "ven_irqtest: staged %zu bytes at carveout+0x%x; injecting IRQ0 (vec 8)\n", n, load_off);

    wr(VEN_R_INTR, VEN_INTR_INTA_SEEN);     // clear any leftover seam state from a prior run
    wr(VEN_R_INTR, 0);

#ifdef PRESTAGE_IVT
    // Coherence test: pre-stage IVT[8] = F000:004C directly in DDR (irq0 is at
    // image offset 0x4C, F-segment offset 0x004C), bypassing the guest's cached
    // L1 write. If the handler now runs, the guest's IVT write wasn't reaching DDR.
    uint16_t hoff = (argc > 2) ? (uint16_t)strtoul(argv[2], 0, 0) : 0x004C;
    g_ddr[0x20] = hoff & 0xFF; g_ddr[0x21] = hoff >> 8;   // IVT[8].offset
    g_ddr[0x22] = 0x00;        g_ddr[0x23] = 0xF0;        // IVT[8].segment = 0xF000
    __sync_synchronize();
    fprintf(stderr, "ven_irqtest: pre-staged IVT[8]=F000:004C in DDR\n");
#endif
    wr(VEN_R_INIT_EIP, entry);
    wr(VEN_R_INIT_ESP, esp);
    wr(VEN_R_MODE, VEN_MODE_L1AXI | VEN_MODE_COSIM | VEN_MODE_BOOT_SYS | VEN_MODE_SOCEN);
    wr(VEN_R_CTRL, VEN_CTRL_CORE_RUN);      // release reset -> run

#ifdef DIAG
    // ---- single-shot diagnostic: is it vectoring, the IVT, or IF? -----------
    // 1) drain the guest's startup I/O (COM1 init + 'A') so IVT[8] is written.
    {
        uint64_t td = now_ms(); int got_a = 0, io = 0;
        while (now_ms() - td < 1500) {
            uint32_t st = rd(VEN_R_STATUS);
            if (st & VEN_ST_IO_REQ) {
                uint32_t ios = rd(VEN_R_IO_STATUS); uint16_t p = (uint16_t)rd(VEN_R_IO_ADDR);
                if ((ios & VEN_IO_IS_WRITE) && (p == 0x3F8 || p == 0xE9)) {
                    int c = rd(VEN_R_IO_WDATA) & 0xFF; putchar(c); fflush(stdout); if (c=='A') got_a=1;
                }
                wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR); io++;
            }
            if (got_a) break;
        }
        // 2) read IVT[8] directly out of the carveout (phys 0x20=off, 0x22=seg).
        uint16_t ivt_off = g_ddr[0x20] | (g_ddr[0x21] << 8);
        uint16_t ivt_seg = g_ddr[0x22] | (g_ddr[0x23] << 8);
        uint32_t r0 = rd(VEN_R_RETIRE_LO);
        fprintf(stderr, "\n[diag] got_a=%d io=%d  IVT[8]=%04x:%04x (expect F000:non-zero)  retire=%u status=0x%08x\n",
                got_a, io, ivt_seg, ivt_off, r0, rd(VEN_R_STATUS));
        // 3) inject vector 8 ONCE, watch INTA + retire delta + 'T' for 1s.
        wr(VEN_R_INTR, VEN_INTR_ASSERT | 0x08);
        fprintf(stderr, "[diag] injected ASSERT|8; watching 1s...\n");
        uint64_t te = now_ms(); int inta=0, tee=0, hio=0;
        while (now_ms() - te < 1000) {
            uint32_t st = rd(VEN_R_STATUS);
            if (st & VEN_ST_IO_REQ) {
                uint32_t ios = rd(VEN_R_IO_STATUS); uint16_t p = (uint16_t)rd(VEN_R_IO_ADDR);
                if ((ios & VEN_IO_IS_WRITE) && (p == 0x3F8 || p == 0xE9)) { int c=rd(VEN_R_IO_WDATA)&0xFF; putchar(c); fflush(stdout); if(c=='T')tee++; }
                wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR); hio++;
            }
            uint32_t seam = rd(VEN_R_INTR);
            if (seam & VEN_INTR_INTA_SEEN) { inta++; wr(VEN_R_INTR, VEN_INTR_INTA_SEEN); }
        }
        uint32_t r1 = rd(VEN_R_RETIRE_LO);
        fprintf(stderr, "[diag] after inject: inta=%d T=%d handler_io=%d  retire %u->%u (d=%d)  status=0x%08x seam=0x%03x\n",
                inta, tee, hio, r0, r1, (int)(r1-r0), rd(VEN_R_STATUS), rd(VEN_R_INTR));
        return (tee >= 1) ? 0 : 3;
    }
#endif

    uint64_t serviced = 0, injected_n = 0, t_chars = 0, inta_n = 0;
    int pending = 0;
    uint64_t t0 = now_ms(), t_last = t0;
    int rc = 1;
    for (;;) {
        uint32_t st = rd(VEN_R_STATUS);
        if (st & VEN_ST_CPU_HUNG) {
            fprintf(stderr, "\nven_irqtest: FAIL — CPU HUNG (bus_err=%d) io=%llu inj=%llu inta=%llu T=%llu\n",
                    !!(st & VEN_ST_BUS_ERR), (unsigned long long)serviced, (unsigned long long)injected_n,
                    (unsigned long long)inta_n, (unsigned long long)t_chars);
            break;
        }
        if (st & VEN_ST_IO_REQ) {
            uint32_t ios  = rd(VEN_R_IO_STATUS);
            uint16_t port = (uint16_t)rd(VEN_R_IO_ADDR);
            if (ios & VEN_IO_IS_WRITE) {
                uint32_t v = rd(VEN_R_IO_WDATA);
                if (port == 0x03F8 || port == 0x00E9) {
                    int c = (int)(v & 0xFF); putchar(c); fflush(stdout);
                    if (c == 'T') t_chars++;
                } else if (port == 0x00F4) {              // isa-debug-exit -> success
                    wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR);
                    fprintf(stderr, "\nven_irqtest: PASS — isa-debug-exit io=%llu inj=%llu inta=%llu T=%llu\n",
                            (unsigned long long)serviced, (unsigned long long)injected_n,
                            (unsigned long long)inta_n, (unsigned long long)t_chars);
                    rc = (t_chars >= 16) ? 0 : 2;
                    goto done;
                }
            }   // (IN requests: none expected here; leave RDATA 0)
            wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR);
            serviced++;
        }

        // INTA handshake: core pulsed inta -> clear seen + deassert, ready for next.
        uint32_t seam = rd(VEN_R_INTR);
        if (seam & VEN_INTR_INTA_SEEN) {
            wr(VEN_R_INTR, VEN_INTR_INTA_SEEN);
            pending = 0; inta_n++;
            if (inta_n <= 4) fprintf(stderr, "[inta #%llu seam=0x%03x]\n", (unsigned long long)inta_n, seam);
        }

        // inject IRQ0 (vector 8) on a wall-clock cadence when none is in flight.
        uint64_t t = now_ms();
        if (!pending && (t - t_last) >= INJECT_MS) {
            wr(VEN_R_INTR, VEN_INTR_ASSERT | 0x08);
            pending = 1; injected_n++; t_last = t;
            if (injected_n <= 4) fprintf(stderr, "[inject #%llu vec=8 status=0x%08x]\n",
                                         (unsigned long long)injected_n, rd(VEN_R_STATUS));
        }
        if (t - t0 > TIMEOUT_MS) {
            fprintf(stderr, "\nven_irqtest: FAIL — timeout io=%llu inj=%llu inta=%llu T=%llu finalstatus=0x%08x seam=0x%03x\n",
                    (unsigned long long)serviced, (unsigned long long)injected_n, (unsigned long long)inta_n,
                    (unsigned long long)t_chars, rd(VEN_R_STATUS), rd(VEN_R_INTR));
            break;
        }
    }
done:
    return rc;
}
