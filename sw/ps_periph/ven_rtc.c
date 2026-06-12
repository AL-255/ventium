// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps_periph/ven_rtc.c — PS C model of the MC146818 RTC/CMOS device.
//
// A 1:1 behavioural port of rtl/soc/ven_rtc.sv (qemu-grounded vs QEMU 8.2.2
// hw/rtc/mc146818rtc.c). Services 0x70-0x71 (index/data) when the RTC is
// PS-placed; verified byte-identical vs qemu-system by the psocdev gate built
// with +VEN_RTC_PS (the C model serves the port range instead of the RTL
// module). The RTL's clocked read side-effects (REG_C read-then-clear, PS/2
// century index remap) become inline read side-effects here — the bridge calls
// io_read once per IN, so the effect is identical.
//
// MODELED (the synchronous, CPU-observable register surface the RTL models):
//   * 128-byte cmos_data[] via the index (0x70) + data (0x71) ports.
//   * index latch (wdata & 0x7f) + the SEPARATE NMI-disable bit (does NOT alias
//     into cmos_data[]); index-port read = 0xFF.
//   * REG_A UIP (0x80) read-only on write; REG_C read-then-clear + irq8 lower;
//     REG_C/REG_D write-ignore; REG_B write -> immediate IRQF raise/lower per
//     (B & C & REG_C_MASK), SET forces UIE off; PS/2 century 0x37 -> 0x32 remap.
//   * Reset defaults (qemu rtc_realizefn): A=0x26, B=0x02, C=0x00, D=0x80, with
//     the deterministic seeded wall time (BCD/24H 2026-06-05 00:00:00, DOW=Fri).
//
// DEFERRED / ORACLE BOUNDARY (real-time-derived in qemu, no host clock here):
//   * The 1 Hz update tick + periodic-interrupt cadence (UIP hold, UF/PF set,
//     BCD increment, SET-freeze) — driven off `clk` in the RTL, not modeled in
//     this register-surface port (the bridge has no clock edge to advance it).
//   * The alarm (AF) match + lost-tick reinjection.

#include "ven_periph.h"
#include <stdlib.h>

// F4 (DOS Quake prep): OPTIONAL extended-memory CMOS seeding — the 1:1 mirror
// of the RTL's `VEN_RTC_EXTMEM_KB (see rtl/soc/ven_rtc.sv header). KB of RAM
// above 1 MiB; 0 (default) = LEGACY: the memory registers keep their all-0x00
// reset value (every existing gate byte-identical). Nonzero seeds the qemu
// pc_cmos_init (hw/i386/pc.c) memory registers at reset. Runtime override:
// ven_rtc_set_extmem_kb() below (takes effect immediately + sticks over reset).
#ifndef VEN_RTC_EXTMEM_KB
#define VEN_RTC_EXTMEM_KB 0
#endif

// CMOS register indices (mc146818rtc_regs.h).
#define RTC_SECONDS       0x00
#define RTC_MINUTES       0x02
#define RTC_HOURS         0x04
#define RTC_DAY_OF_WEEK   0x06
#define RTC_DAY_OF_MONTH  0x07
#define RTC_MONTH         0x08
#define RTC_YEAR          0x09
#define RTC_REG_A         0x0A
#define RTC_REG_B         0x0B
#define RTC_REG_C         0x0C
#define RTC_REG_D         0x0D
#define RTC_CENTURY       0x32
#define RTC_PS2_CENTURY   0x37

// Bit masks (mc146818rtc_regs.h).
#define REG_A_UIP   0x80
#define REG_B_UIE   0x10
#define REG_C_IRQF  0x80
#define REG_C_MASK  0x70   // PF|AF|UF (interrupt sources)

typedef struct {
    uint8_t  cmos_data[128];  // 128-byte CMOS
    uint8_t  cmos_index;      // latched index (wdata & 0x7f), 7-bit
    uint8_t  nmi_disable;     // bit7 of last index write (stored separately)
    uint8_t  irq8;            // registered irq8 level (1 = asserting)
    uint32_t extmem_kb;       // F4: KB above 1 MiB to seed at reset (0 = legacy)
} rtc_state_t;

// F4: seed the qemu pc_cmos_init memory-size registers (hw/i386/pc.c) with
// below_4g = 1 MiB + extmem_kb KB and no >4GiB memory. Mirrors the RTL's
// SEED_EXT_KB / SEED_EXT64K localparams exactly. No-op when extmem_kb == 0.
static void rtc_seed_extmem(rtc_state_t* s) {
    uint32_t ext_kb, b4g_kb, ext64k;
    if (s->extmem_kb == 0) return;
    b4g_kb = 1024u + s->extmem_kb;                       // total <4G mem in KB
    ext_kb = (s->extmem_kb > 65535u) ? 65535u : s->extmem_kb;
    ext64k = (b4g_kb > 16u*1024u) ? ((b4g_kb - 16u*1024u) / 64u) : 0u;
    if (ext64k > 65535u) ext64k = 65535u;
    s->cmos_data[0x15] = 0x80;                           // base mem 640 = 0x0280
    s->cmos_data[0x16] = 0x02;
    s->cmos_data[0x17] = (uint8_t)(ext_kb & 0xFF);       // legacy alias of 0x30/31
    s->cmos_data[0x18] = (uint8_t)(ext_kb >> 8);
    s->cmos_data[0x30] = (uint8_t)(ext_kb & 0xFF);       // CMOS_MEM_EXTMEM: KB >1MiB
    s->cmos_data[0x31] = (uint8_t)(ext_kb >> 8);
    s->cmos_data[0x34] = (uint8_t)(ext64k & 0xFF);       // CMOS_MEM_EXTMEM2: 64KB >16MiB
    s->cmos_data[0x35] = (uint8_t)(ext64k >> 8);
}

// effective index for this access (PS/2 century 0x37 aliases to 0x32).
static uint8_t rtc_eff_index(uint8_t idx) {
    return (idx == RTC_PS2_CENTURY) ? (uint8_t)RTC_CENTURY : idx;
}

static void rtc_reset(ven_periph_t* p) {
    rtc_state_t* s = (rtc_state_t*)p->state;
    int i;
    for (i = 0; i < 128; i = i + 1) s->cmos_data[i] = 0x00;
    // qemu rtc_realizefn defaults
    s->cmos_data[RTC_REG_A] = 0x26;
    s->cmos_data[RTC_REG_B] = 0x02;   // 24H, BCD
    s->cmos_data[RTC_REG_C] = 0x00;
    s->cmos_data[RTC_REG_D] = 0x80;   // VRT
    // seed a deterministic wall time (BCD, 24H): 2026-06-05 00:00:00, DOW=Fri(6)
    s->cmos_data[RTC_SECONDS]      = 0x00;
    s->cmos_data[RTC_MINUTES]      = 0x00;
    s->cmos_data[RTC_HOURS]        = 0x00;
    s->cmos_data[RTC_DAY_OF_WEEK]  = 0x06;  // 1=Sun..7=Sat ; Fri=6
    s->cmos_data[RTC_DAY_OF_MONTH] = 0x05;
    s->cmos_data[RTC_MONTH]        = 0x06;
    s->cmos_data[RTC_YEAR]         = 0x26;  // year %100 = 26
    s->cmos_data[RTC_CENTURY]      = 0x20;  // 20xx
    rtc_seed_extmem(s);                     // F4 (no-op when extmem_kb == 0)
    s->cmos_index   = 0x00;
    s->nmi_disable  = 0x00;
    s->irq8         = 0x00;
}

static uint8_t rtc_read(ven_periph_t* p, uint16_t port) {
    rtc_state_t* s = (rtc_state_t*)p->state;
    uint8_t rd_idx, rdata;

    // index port (addr[0]==0, even) reads back 0xFF — write-only.
    if ((port & 1) == 0) {
        return 0xFF;
    }

    // data port (addr[0]==1, odd). PS/2 century read alias remaps the latched
    // index (qemu remaps then falls through) — this is the clocked read
    // side-effect, applied inline.
    if (s->cmos_index == RTC_PS2_CENTURY) s->cmos_index = RTC_CENTURY;
    rd_idx = rtc_eff_index(s->cmos_index);

    // Compute the returned byte off the PRE-clear latched register state.
    if (rd_idx == RTC_REG_A) {
        // UIP (0x80) read-only; structural pre-tick UIP window is not modeled
        // here (no host clock) -> UIP reads back 0.
        rdata = (uint8_t)(s->cmos_data[RTC_REG_A] & ~REG_A_UIP);
    } else {
        rdata = s->cmos_data[rd_idx];
    }

    // REG_C READ-then-CLEAR: zero REG_C and LOWER irq8 (critical side effect).
    if (rd_idx == RTC_REG_C) {
        s->cmos_data[RTC_REG_C] = 0x00;
        s->irq8 = 0x00;
    }

    return rdata;
}

static void rtc_write(ven_periph_t* p, uint16_t port, uint8_t val) {
    rtc_state_t* s = (rtc_state_t*)p->state;
    uint8_t eff, new_b;

    if ((port & 1) == 0) {
        // index port (even): latch addr & store the NMI-disable bit separately.
        s->cmos_index  = (uint8_t)(val & 0x7F);
        s->nmi_disable = (uint8_t)((val >> 7) & 0x1);
        return;
    }

    // data port (odd): per-register write rules (qemu cmos_ioport_write).
    eff = rtc_eff_index(s->cmos_index);
    switch (eff) {
        case RTC_REG_A:
            // UIP (0x80) is read-only: keep the live UIP, take the rest.
            s->cmos_data[RTC_REG_A] =
                (uint8_t)((val & ~REG_A_UIP) |
                          (s->cmos_data[RTC_REG_A] & REG_A_UIP));
            break;
        case RTC_REG_B:
            new_b = val;
            // SET mode also forces UIE off (qemu: data &= ~REG_B_UIE).
            if (new_b & 0x80) new_b = (uint8_t)(new_b & ~REG_B_UIE);
            s->cmos_data[RTC_REG_B] = new_b;
            // If enabling an IRQ whose flag is already pending -> raise now;
            // else clear IRQF + lower irq8. (qemu REG_B write tail.)
            if ((uint8_t)(new_b & s->cmos_data[RTC_REG_C] & REG_C_MASK) != 0x00) {
                s->cmos_data[RTC_REG_C] =
                    (uint8_t)(s->cmos_data[RTC_REG_C] | REG_C_IRQF);
                s->irq8 = 0x01;
            } else {
                s->cmos_data[RTC_REG_C] =
                    (uint8_t)(s->cmos_data[RTC_REG_C] & ~REG_C_IRQF);
                s->irq8 = 0x00;
            }
            break;
        case RTC_REG_C:
        case RTC_REG_D:
            // read-only: write ignored
            break;
        default:
            s->cmos_data[eff] = val;
            break;
    }

    // PS/2 century alias: qemu remaps cmos_index to RTC_CENTURY on a write to
    // 0x37 (it sticks). Mirror that.
    if (s->cmos_index == RTC_PS2_CENTURY) s->cmos_index = RTC_CENTURY;
}

static int rtc_irq(ven_periph_t* p) {
    const rtc_state_t* s = (const rtc_state_t*)p->state;
    return s->irq8 ? 1 : 0;
}

// F4: runtime extended-memory override (e.g. the A53 PS app sizing the CMOS to
// the actual DDR carve-out). Re-seeds the memory registers immediately and the
// new size sticks across subsequent reset() calls. kb == 0 restores legacy.
void ven_rtc_set_extmem_kb(ven_periph_t* p, uint32_t kb) {
    rtc_state_t* s = (rtc_state_t*)p->state;
    s->extmem_kb = kb;
    if (kb == 0) {                          // legacy: memory regs read 0x00
        s->cmos_data[0x15] = s->cmos_data[0x16] = 0x00;
        s->cmos_data[0x17] = s->cmos_data[0x18] = 0x00;
        s->cmos_data[0x30] = s->cmos_data[0x31] = 0x00;
        s->cmos_data[0x34] = s->cmos_data[0x35] = 0x00;
    } else {
        rtc_seed_extmem(s);
    }
}

ven_periph_t* ven_rtc_new(void) {
    ven_periph_t* p = (ven_periph_t*)calloc(1, sizeof(ven_periph_t));
    p->state    = calloc(1, sizeof(rtc_state_t));
    p->reset    = rtc_reset;
    p->io_read  = rtc_read;
    p->io_write = rtc_write;
    p->irq      = rtc_irq;
    ((rtc_state_t*)p->state)->extmem_kb = VEN_RTC_EXTMEM_KB;  // compile-time default
    rtc_reset(p);
    return p;
}
