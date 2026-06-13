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

#define _GNU_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>
#include "ven_soc_regs.h"
#include "hid_kbd.h"
#include "../../ps_periph/ven_periph.h"

// F3 PS-placed peripheral C models (sw/ps_periph/, same files the cosim gates
// prove bit-exact vs qemu-system) + their F3 extras.
ven_periph_t* ven_i8042_new(void);
ven_periph_t* ven_pic_new(void);
ven_periph_t* ven_vgaregs_new(void);
void          ven_pic_set_irq(ven_periph_t*, int irq, int level);
uint8_t       ven_pic_peek_vector(ven_periph_t*);
uint8_t       ven_pic_intack(ven_periph_t*);
const uint8_t* ven_vgaregs_dac(ven_periph_t*);
// F-track FreeDOS stack: PIT (timer/IRQ0), RTC/CMOS, IDE/ATA disk.
ven_periph_t* ven_pit_new(void);
int           ven_pit_irq0_ticks(ven_periph_t*);
ven_periph_t* ven_rtc_new(void);
ven_periph_t* ven_ide_new(const char* disk_path);

static volatile uint32_t *g_reg;     // mmap'd AXI-Lite slave
static volatile uint8_t  *g_ddr;     // mmap'd DDR carveout

static inline uint32_t rd(uint32_t off)          { return g_reg[off >> 2]; }
static inline void     wr(uint32_t off, uint32_t v) { g_reg[off >> 2] = v; }

// VEN_DBG=1: print the retire trajectory + status/last-io every ~250 ms so a
// silent stall (status=0, retire frozen) is visible (no CPU_HUNG is raised).
static long dbg_now_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

// ---- F3 (--dos) state --------------------------------------------------------
static int           g_dos = 0;          // --dos: i8042/PIC/VGA models + IRQ inject
static ven_periph_t *g_i8042, *g_pic, *g_vga, *g_pit, *g_rtc, *g_ide;
static int           g_dac_dirty = 0;    // guest wrote the DAC -> re-export
static const char   *VGA_DAC_EXPORT = "/dev/shm/ven_vga_dac";

// export the live 6-bit DAC for the fb_vnc daemon (768 bytes, atomic-enough:
// readers tolerate a torn palette for one frame).
static void export_dac(void) {
    int fd = open(VGA_DAC_EXPORT, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    if (write(fd, ven_vgaregs_dac(g_vga), 768) != 768) { /* best effort */ }
    close(fd);
}

// --- console / device emulation (the part that grows for F3/F4) --------------
// F2: a tiny UART. OUT to 0x3F8 (COM1 THR) or 0xE9 (debug) -> stdout. IN from the
// COM1 LSR (0x3FD) returns "THR empty, data ready" so a UART-poll loop proceeds.
// F3 (--dos): the dual-8259 PIC, the i8042 and the VGA register file route to
// their sw/ps_periph C models first; everything else keeps the F2 behavior.

// --dos port routing: 1 if the port belongs to a PS-placed C model.
static ven_periph_t* dos_model_of(uint16_t port) {
    if (!g_dos) return 0;
    if (port == 0x60 || port == 0x64)                  return g_i8042;
    if (port == 0x20 || port == 0x21 ||
        port == 0xA0 || port == 0xA1 ||
        port == 0x4D0 || port == 0x4D1)                return g_pic;
    if (port >= 0x3B0 && port <= 0x3DF)                return g_vga;
    if (port >= 0x40 && port <= 0x43)                  return g_pit;   // 8254 PIT
    if (port == 0x70 || port == 0x71)                  return g_rtc;   // RTC/CMOS
    if ((port >= 0x1F0 && port <= 0x1F7) || port == 0x3F6) return g_ide;  // IDE/ATA
    return 0;
}

static int service_out(uint16_t port, uint32_t val) {
    ven_periph_t* m = dos_model_of(port);
    if (m) {
        m->io_write(m, port, (uint8_t)(val & 0xFF));
        if (port == 0x3C8 || port == 0x3C9) g_dac_dirty = 1;  // DAC write -> export
        return 0;
    }
    switch (port) {
        case 0x00E9:                       // bochs/qemu debug console
        case 0x03F8: putchar((int)(val & 0xFF)); fflush(stdout); return 0;
        case 0x00F4: return 1;             // isa-debug-exit -> stop the run
        default:     return 0;             // ignore unmodeled OUTs (F3 fills these in)
    }
}
static uint32_t service_in(uint16_t port, uint8_t size) {
    ven_periph_t* m = dos_model_of(port);
    if (m) {
        if (size >= 2 && m->io_read16) return m->io_read16(m, port);  // IDE data port (0x1F0)
        return m->io_read(m, port);        // byte-wide devices
    }
    switch (port) {
        case 0x03FD: return 0x60;          // COM1 LSR: THR-empty | TSR-empty
        case 0x03F8: return 0x00;          // COM1 RBR: no input byte
        default:     return 0xFF;          // unmodeled IN -> all-ones (F3 fills these in)
    }
}

int main(int argc, char **argv) {
    // positional args exactly as F2 (<program.bin> [load_off] [entry] [esp]);
    // flags may appear anywhere: --sys, --dos, --kbd <evdev-path>.
    const char *img = 0, *kbd_path = 0, *bios = 0, *disk = 0;
    uint32_t pos[3] = {0x0, 0x0, 0x000FFFF0};    // load_off, entry, esp
    int      npos = 0, sysmode = 0, i;
    for (i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--sys")) sysmode = 1;
        else if (!strcmp(argv[i], "--dos")) g_dos   = 1;
        else if (!strcmp(argv[i], "--kbd")  && i + 1 < argc) kbd_path = argv[++i];
        else if (!strcmp(argv[i], "--bios") && i + 1 < argc) bios = argv[++i];  // SeaBIOS image
        else if (!strcmp(argv[i], "--disk") && i + 1 < argc) disk = argv[++i];  // IDE disk image
        else if (!img)      img = argv[i];
        else if (npos < 3)  pos[npos++] = strtoul(argv[i], 0, 0);
    }
    if (!img && !bios) {
        fprintf(stderr, "usage: %s <program.bin> [load_off] [entry] [esp] [--sys] [--dos]\n"
                        "       [--kbd /dev/input/eventN] [--bios seabios.bin --disk hd.img]\n", argv[0]);
        return 2;
    }
    if (bios) sysmode = 1;   // a BIOS boots from the reset vector F000:FFF0
    uint32_t load_off = pos[0], entry = pos[1], esp = pos[2];

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    g_reg = mmap(0, VEN_HPM0_SIZE,     PROT_READ|PROT_WRITE, MAP_SHARED, fd, VEN_HPM0_BASE);
    g_ddr = mmap(0, VEN_CARVEOUT_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, VEN_CARVEOUT_BASE);
    if (g_reg == MAP_FAILED || g_ddr == MAP_FAILED) { perror("mmap"); return 1; }

    uint32_t ident = rd(VEN_R_IDENT);
    if (ident != VEN_IDENT_MAGIC) { fprintf(stderr, "bad IDENT 0x%08x (slave not present?)\n", ident); return 1; }

    // hold the core in reset (CORE_RUN=0 by default at slave reset), stage the image.
    wr(VEN_R_CTRL, 0);                                   // ensure CORE_RUN=0
    if (bios) {
        // FreeDOS: stage the SeaBIOS image at the low shadow (0xE0000) AND the
        // top-of-4G shadow, which the L1/AXI ADDR_MASK wrap folds to carveout offset
        // 0x0FFE0000 (phys 0xFFFE0000 & 0x0FFF_FFFF). SeaBIOS runs its 32-bit POST from
        // the high shadow; both copies must be present. The disk is served by the IDE
        // model from --disk (NOT staged into RAM). Boot from the reset vector.
        FILE *f = fopen(bios, "rb");
        if (!f) { perror(bios); return 1; }
        static uint8_t biosbuf[131072];                  // 128 KiB BIOS region
        size_t bn = fread(biosbuf, 1, sizeof(biosbuf), f);
        fclose(f);
        memcpy((void *)(g_ddr + 0x000E0000), biosbuf, bn);   // low shadow 0xE0000-0xFFFFF
        memcpy((void *)(g_ddr + 0x0FFE0000), biosbuf, bn);   // wrapped 4G-top shadow
        __sync_synchronize();
        fprintf(stderr, "ven_soc: staged %zu-byte BIOS at 0xE0000 + 0x0FFE0000 (4G alias); disk=%s\n",
                bn, disk ? disk : "(none)");
    } else {
        FILE *f = fopen(img, "rb");
        if (!f) { perror(img); return 1; }
        size_t n = fread((void *)(g_ddr + load_off), 1, VEN_CARVEOUT_SIZE - load_off, f);
        fclose(f);
        __sync_synchronize();                            // flush the image to DRAM before run
        fprintf(stderr, "ven_soc: loaded %zu bytes at carveout+0x%x; entry=0x%x esp=0x%x %s\n",
                n, load_off, entry, esp, sysmode ? "[system]" : "[user]");
    }

    // F3 (--dos): instantiate the PS-placed peripheral C models + the keyboard.
    if (g_dos) {
        g_i8042 = ven_i8042_new();
        g_pic   = ven_pic_new();
        g_vga   = ven_vgaregs_new();
        g_pit   = ven_pit_new();                         // 8254 timer (IRQ0)
        g_rtc   = ven_rtc_new();                          // RTC/CMOS (RAM-size, time)
        g_ide   = ven_ide_new(disk);                      // IDE/ATA disk (INT13 source)
        if (hid_kbd_open(kbd_path) < 0)
            fprintf(stderr, "ven_soc: --dos without a keyboard (display only)\n");
        export_dac();                                    // publish the reset palette
    }

    // boot config: route memory via L1/AXI (mode 2) + IN/OUT via the io bridge.
    // --dos additionally sets SOCEN: it ungates the core's external-interrupt
    // divert (and selects the qemu-system CPUID arm the FreeDOS golden used).
    wr(VEN_R_INTR, VEN_INTR_INTA_SEEN);  // clear any leftover injection from a prior run
    wr(VEN_R_INTR, 0);                    // (else a stale ASSERT|vec derails the fresh core)
    wr(VEN_R_INIT_EIP, entry);
    wr(VEN_R_INIT_ESP, esp);
    wr(VEN_R_MODE, VEN_MODE_L1AXI | VEN_MODE_COSIM
                 | (sysmode ? VEN_MODE_BOOT_SYS : 0)
                 | (g_dos   ? VEN_MODE_SOCEN    : 0));
    wr(VEN_R_CTRL, VEN_CTRL_CORE_RUN);                   // release reset -> run

    // service loop (F2: poll; F3+ can switch to the GIC interrupt on irq_out).
    uint64_t serviced = 0;
    uint32_t intr_shadow = 0;        // last R_INTR value we wrote (vector|assert)
    uint32_t housekeep   = 0;
    static int  dbg = -1;
    static long dbg_last = 0;
    if (dbg < 0) dbg = getenv("VEN_DBG") ? 1 : 0;
    for (;;) {
        uint32_t st = rd(VEN_R_STATUS);
        if (dbg) {
            long now = dbg_now_ms();
            if (now - dbg_last >= 250) {
                dbg_last = now;
                uint32_t lo = rd(VEN_R_RETIRE_LO), hi = rd(VEN_R_RETIRE_HI);
                fprintf(stderr, "[dbg t=%ldms] retire=0x%x%08x st=0x%x ioaddr=0x%x iostat=0x%x intr=0x%x io=%llu\n",
                        now, hi, lo, st, rd(VEN_R_IO_ADDR), rd(VEN_R_IO_STATUS), rd(VEN_R_INTR),
                        (unsigned long long)serviced);
            }
        }
        if (st & VEN_ST_CPU_HUNG) { fprintf(stderr, "\nven_soc: CPU HUNG (bus_err=%d) after %llu io\n",
                                            !!(st & VEN_ST_BUS_ERR), (unsigned long long)serviced); break; }
        if (st & VEN_ST_IO_REQ) {
            uint32_t ios  = rd(VEN_R_IO_STATUS);
            uint16_t port = (uint16_t)rd(VEN_R_IO_ADDR);
            if (ios & VEN_IO_IS_WRITE) {
                uint32_t v = rd(VEN_R_IO_WDATA);
                if (dbg) fprintf(stderr, "[io %llu] OUT 0x%03x = 0x%x\n",
                                 (unsigned long long)serviced, port, v);
                if (service_out(port, v)) {              // out 0xf4 -> done
                    wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR);
                    fprintf(stderr, "\nven_soc: isa-debug-exit after %llu io\n", (unsigned long long)serviced);
                    break;
                }
            } else {
                uint32_t rv = service_in(port, (uint8_t)rd(VEN_R_IO_SIZE));
                if (dbg) fprintf(stderr, "[io %llu] IN  0x%03x -> 0x%x\n",
                                 (unsigned long long)serviced, port, rv);
                wr(VEN_R_IO_RDATA, rv);
            }
            wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR);   // release the stalled core
            serviced++;
        }

        // ---- F3 interrupt pump (the PS *is* the PIC + keyboard) ---------------
        if (g_dos) {
            uint32_t seam, desired;
            static int pit_pending = 0;
            // 1. USB keyboard -> scancode FIFO -> i8042 OBF (one byte at a time)
            hid_kbd_poll();
            hid_kbd_pump(g_i8042);
            // 2. PIT IRQ0 on WALL-CLOCK (must fire even while the core is HLT-waiting for
            //    the timer — a retire-paced tick deadlocks, since a HLT freezes the retire
            //    count below the threshold). ~18.2 Hz; the ISR is ~us of a 55 ms period so
            //    the mainline is never starved. The PIC-programmed gate (step 5) blocks the
            //    pre-pic_setup vector-0 that would otherwise derail early POST.
            if (ven_pit_irq0_ticks(g_pit) > 0) pit_pending = 1;
            // 3. drive the 8259 IR lines: IRQ0 (timer), IRQ1 (kbd), IRQ14 (IDE)
            ven_pic_set_irq(g_pic, 0,  pit_pending);
            ven_pic_set_irq(g_pic, 1,  g_i8042->irq(g_i8042));
            ven_pic_set_irq(g_pic, 14, g_ide->irq(g_ide));
            // 4. INTA boundary: the core took our injection -> intack the PIC model
            //    (ISR set/IRR clear, the RTL ven_pic inta path); clear the serviced
            //    source's latch (IRQ0 re-arms on the next tick).
            seam = rd(VEN_R_INTR);
            if (seam & VEN_INTR_INTA_SEEN) {
                uint8_t vec = ven_pic_intack(g_pic);
                if (vec == 0x08) pit_pending = 0;        // IRQ0 (PIC base 0x08) serviced
                wr(VEN_R_INTR, VEN_INTR_INTA_SEEN);      // W1C (and deassert)
                intr_shadow = 0;
            }
            // 5. mirror the PIC INT level + vector into the seam — but ONLY once the PIC
            //    is programmed (vector >= 0x08). An unprogrammed PIC (early POST, ICW2=0)
            //    would present vector 0; injecting that derails the core. Gate it off.
            uint8_t pv = ven_pic_peek_vector(g_pic);
            desired = (g_pic->irq(g_pic) && pv >= 0x08) ? (VEN_INTR_ASSERT | pv) : 0;
            if (desired != intr_shadow) { wr(VEN_R_INTR, desired); intr_shadow = desired; }
            // 6. periodic: publish the DAC for the fb_vnc daemon
            if ((++housekeep & 0xFFFF) == 0 && g_dac_dirty) { export_dac(); g_dac_dirty = 0; }
        }
        // (no busy-spin throttle here; F3 sleeps on the GIC irq via UIO instead.)
    }
    if (g_dos) { if (g_dac_dirty) export_dac(); hid_kbd_close(); }
    return 0;
}
