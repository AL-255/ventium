// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// verif/gls/gls_dpi.cpp — DPI-C glue for the xsim gate-level FreeDOS harness.
//
// The SV testbench (tb_gls_soc.sv) drives the synthesized ventium_top netlist.
// xsim cannot link the Verilator C++ models directly, so this file re-exposes
// the SAME C/C++ models the Verilator tb_main.cpp uses (MemModel + the PS
// peripheral C models in sw/ps_periph/*.c) as DPI-C functions:
//
//   gls_init(disk, bios)            : construct MemModel + the 6 PS peripheral
//                                     models, load seabios.bin so its last byte
//                                     is at phys 0xFFFFF (+ KV260 4G-top alias),
//                                     attach the FreeDOS disk to ven_ide.
//   gls_mem_read32(addr)            : behavioral AXI4 DDR slave read backing
//   gls_mem_write32(addr,data,wstrb): behavioral AXI4 DDR slave write backing
//                                     (both x86-phys-indexed; the SV slave has
//                                     already stripped the KV260 AXI_REMAP).
//   gls_io_service(...)             : the service_io() port dispatch — ONE
//                                     side-effect per io_req assertion. Read
//                                     returns rdata+ack; write consumes + acks.
//   gls_irq_poll(cycle)             : the F3 IRQ0 timer pump — raise IRQ0 every
//                                     period, return {intr, vector} for the
//                                     core's intr seam.
//   gls_inta(vec)                   : INTA boundary — intack the PIC model.
//
// This is a faithful port of the seams in verif/tb/tb_main.cpp; see the inline
// references. It deliberately reuses memmodel.cpp + sw/ps_periph/*.c verbatim
// (compiled into the same xsc shared object) — nothing is reimplemented.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "svdpi.h"
#include "memmodel.h"

extern "C" {
#include "ven_periph.h"
}

// The PS peripheral-model constructors (sw/ps_periph/*.c, compiled as C).
extern "C" {
ven_periph_t* ven_i8042_new(void);
ven_periph_t* ven_pic_new(void);
ven_periph_t* ven_vgaregs_new(void);
ven_periph_t* ven_pit_new(void);
ven_periph_t* ven_rtc_new(void);
ven_periph_t* ven_ide_new(const char* disk_path);
void          ven_pic_set_irq(ven_periph_t*, int irq, int level);
uint8_t       ven_pic_peek_vector(ven_periph_t*);
uint8_t       ven_pic_intack(ven_periph_t*);
}

namespace {

ventium::MemModel*  g_mem  = nullptr;
ven_periph_t*       g_pit  = nullptr;
ven_periph_t*       g_rtc  = nullptr;
ven_periph_t*       g_pic  = nullptr;
ven_periph_t*       g_i8042= nullptr;
ven_periph_t*       g_vga  = nullptr;
ven_periph_t*       g_ide  = nullptr;

// F3 IRQ0 timer-pump state (mirrors tb_main.cpp DOS_IRQ0_PERIOD pump).
uint64_t g_irq0_period = 8000;
uint64_t g_irq0_next   = 8000;
int      g_pit_pending = 0;

// service_io side-effect-once guard (mirrors io_serviced/io_held_rdata).
bool     g_io_serviced = false;
uint32_t g_io_held     = 0;

// diagnostics
uint64_t g_io_in = 0, g_io_out = 0;

// Map a port to its PS peripheral model (verif/tb/tb_main.cpp dos_model_of).
ven_periph_t* dos_model_of(uint16_t port) {
    if (port == 0x60 || port == 0x64) return g_i8042;
    if (port == 0x20 || port == 0x21 || port == 0xA0 || port == 0xA1 ||
        port == 0x4D0 || port == 0x4D1) return g_pic;
    if (port >= 0x3B0 && port <= 0x3DF) return g_vga;
    if (port >= 0x40 && port <= 0x43) return g_pit;
    if (port == 0x70 || port == 0x71) return g_rtc;
    if ((port >= 0x1F0 && port <= 0x1F7) || port == 0x3F6) return g_ide;
    return nullptr;
}

} // namespace

extern "C" {

// gls_init: construct everything + load the BIOS image. disk may be "" (no IDE).
// Mirrors tb_main.cpp's --system image load + the VEN_KV260_SOC 4G-top alias +
// the --dos peripheral-model construction. Returns 0 on success.
int gls_init(const char* disk, const char* bios) {
    if (!g_mem) g_mem = new ventium::MemModel();

    // --system BIOS load: image's LAST byte at 0x000FFFFF (load = 0x100000 - sz).
    long sz = 0;
    { FILE* f = std::fopen(bios, "rb");
      if (!f) { std::fprintf(stderr, "gls: cannot open bios '%s'\n", bios); return 2; }
      std::fseek(f, 0, SEEK_END); sz = std::ftell(f); std::fclose(f); }
    if (sz <= 0 || sz > 0x00100000) {
        std::fprintf(stderr, "gls: bad bios size %ld\n", sz); return 2;
    }
    uint32_t load_at = (uint32_t)(0x00100000u - (uint32_t)sz);
    long n = g_mem->load_image(bios, load_at);
    if (n < 0) { std::fprintf(stderr, "gls: failed to load bios\n"); return 2; }
    std::fprintf(stderr, "gls: loaded %ld bytes at 0x%08x from %s (bios)\n",
                 n, load_at, bios);

    // KV260 4G-top alias: the deployed bitstream folds the high BIOS ROM window
    // into the DDR carveout via the L1AXI_ADDR_MASK=0x0FFF_FFFF wrap. After the
    // SV slave strips AXI_REMAP it sees the MASKED phys, so stage the same copy.
    if (sz > 0x10000) {
        uint32_t hi_masked = (uint32_t)((0u - (uint32_t)sz) & 0x0FFFFFFFu);
        g_mem->load_image(bios, hi_masked);
        std::fprintf(stderr, "gls: KV260 4G-top alias (masked) at 0x%08x\n", hi_masked);
    }

    // --dos PS peripheral C models (same code ven_soc_app runs on the KV260).
    g_pit = ven_pit_new();
    g_rtc = ven_rtc_new();
    g_pic = ven_pic_new();
    g_i8042 = ven_i8042_new();
    g_vga = ven_vgaregs_new();
    g_ide = (disk && disk[0]) ? ven_ide_new(disk) : nullptr;
    std::fprintf(stderr, "gls: PS peripheral C models wired (disk=%s)\n",
                 (disk && disk[0]) ? disk : "(none)");

    // env override of the IRQ0 period (mirrors VEN_IRQ0_PERIOD).
    if (const char* e = std::getenv("VEN_IRQ0_PERIOD")) {
        g_irq0_period = (uint64_t)strtoull(e, nullptr, 0);
        if (!g_irq0_period) g_irq0_period = 8000;
    }
    g_irq0_next = g_irq0_period;
    return 0;
}

// Behavioral AXI4 DDR slave backing — x86-phys-indexed (SV slave stripped REMAP).
unsigned int gls_mem_read32(unsigned int addr) {
    if (!g_mem) return 0;
    return g_mem->read32(addr);
}

// wstrb is the 4-bit per-byte write enable; the SV slave passes the WORD-ALIGNED
// address (it already aligned awaddr & ~3 like the faithful DDR model in tb_main).
void gls_mem_write32(unsigned int addr, unsigned int data, unsigned int wstrb) {
    if (!g_mem) return;
    uint32_t aligned = addr & ~3u;
    uint32_t old = g_mem->read32(aligned), nw = 0;
    for (int b = 0; b < 4; b++) {
        uint32_t by = ((wstrb >> b) & 1) ? ((data >> (b * 8)) & 0xff)
                                         : ((old >> (b * 8)) & 0xff);
        nw |= by << (b * 8);
    }
    g_mem->write32(aligned, nw);
}

// gls_io_service: the service_io() port dispatch, ONE side-effect per io_req
// assertion. The SV testbench calls this on the rising-edge service phase while
// io_req is asserted, and calls gls_io_idle() when io_req deasserts so the next
// op re-arms. Returns rdata (in *rdata) + ack (return value, 1=ack).
//   we   : io_we (1=OUT/write, 0=IN/read)
//   addr : io_addr (port)
//   size : io_size (1/2/4 bytes)
//   wdata: io_wdata (write data)
int gls_io_service(int we, int addr, int size, unsigned int wdata,
                   unsigned int* rdata) {
    const uint32_t port = (uint32_t)addr & 0xffff;
    const uint32_t sz   = (uint32_t)size;

    if (g_io_serviced) { *rdata = g_io_held; return 1; }  // hold across S_IO clocks
    g_io_serviced = true;

    if (we) {
        // OUT: the CPU drives the value; consume it. isa-debug-exit 0xf4 -> the
        // SV tb watches the return flag bit (0x100) to terminate.
        if (port == 0xf4) { *rdata = 0; ++g_io_out; g_io_held = 0; return 0x101; }
        if (ven_periph_t* m = dos_model_of((uint16_t)port)) {
            if (sz >= 2 && m->io_write16) m->io_write16(m, (uint16_t)port, (uint16_t)wdata);
            else                          m->io_write(m, (uint16_t)port, (uint8_t)(wdata & 0xff));
        } else if (port == 0x3f8 || port == 0xe9 || port == 0x402) {
            std::putchar((int)(wdata & 0xff)); std::fflush(stdout);  // COM1 / dbg
        }
        g_io_held = 0;
        ++g_io_out;
        *rdata = 0;
        return 1;
    } else {
        // IN: open-bus default 0xFF.. (a real PC floats an unmodeled port high);
        // the modeled ports answer via the PS C-models.
        uint32_t v = (sz == 1) ? 0xFFu : (sz == 2) ? 0xFFFFu : 0xFFFFFFFFu;
        if (ven_periph_t* m = dos_model_of((uint16_t)port)) {
            v = (sz >= 2 && m->io_read16) ? m->io_read16(m, (uint16_t)port)
                                          : m->io_read(m, (uint16_t)port);
        } else if (port == 0x3fd) { v = 0x60;   // COM1 LSR (TX ready)
        } else if (port == 0x3f8) { v = 0x00;   // COM1 RBR
        }
        g_io_held = v;
        ++g_io_in;
        *rdata = v;
        return 1;
    }
}

// Called by the SV tb when io_req deasserts: re-arm the once-per-assertion guard.
void gls_io_idle(void) { g_io_serviced = false; }

// F3 IRQ0 timer pump (mirrors tb_main.cpp DOS IRQ pump). Returns the packed
// {vector[7:0], intr[8]} the SV tb drives on the core's intr/inta_vector seam.
int gls_irq_poll(unsigned long long cycle) {
    if (!g_pic) return 0;
    if (cycle >= g_irq0_next) { g_pit_pending = 1; g_irq0_next = cycle + g_irq0_period; }
    ven_pic_set_irq(g_pic, 0, g_pit_pending);
    uint8_t pv = ven_pic_peek_vector(g_pic);
    if (g_pic->irq(g_pic) && pv >= 0x08) return (int)((1u << 8) | pv);
    return 0;
}

// INTA boundary: the core took the injected vector this clock -> intack the PIC.
void gls_inta(void) {
    if (!g_pic) return;
    uint8_t vec = ven_pic_intack(g_pic);
    if (vec == 0x08) g_pit_pending = 0;
}

// Diagnostics readout at end-of-run.
void gls_io_stats(unsigned long long* in, unsigned long long* out) {
    *in = g_io_in; *out = g_io_out;
}

} // extern "C"
