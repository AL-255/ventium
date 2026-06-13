// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps_periph/ven_pit.c — Intel 8254 PIT C model (PS-placed peripheral).
//
// 1:1 port of the CPU-observable register behavior of rtl/soc/ven_pit.sv (itself a
// port of QEMU 8.2.2 hw/timer/i8254.c). Ports 0x40-0x43; addr&3 selects channel /
// command. The elapsed-tick value `d` (QEMU's muldiv64(now-load, PIT_FREQ, 1e9))
// is computed from the host wall-clock here — MORE faithful to QEMU than the RTL's
// clk-derived prescaler, and it makes ch0 OUT (IRQ0) tick at the real ~18.2 Hz so
// SeaBIOS/FreeDOS timer waits progress. Channel 0 OUT is the IRQ0 source; the app
// pumps ven_pit_irq0_ticks() into the PIC's IR0 (one IRQ0 per elapsed period).
//
// Register model matches ven_pit.sv exactly (so the psocpit cosim gate stays
// "C model == RTL == qemu"); only the time base differs (wall-clock vs clk).

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "ven_periph.h"

#define PIT_FREQ 1193182u
#define RW_MSB   2
#define RW_WORD0 3
#define RW_WORD1 4

typedef struct {
    uint32_t count[3];          // 1..0x10000
    uint16_t latched_count[3];
    uint8_t  count_latched[3];  // 0=not latched, else RW_*
    uint8_t  status_latched[3];
    uint8_t  status[3];
    uint8_t  read_state[3];
    uint8_t  write_state[3];
    uint8_t  write_latch[3];
    uint8_t  rw_mode[3];
    uint8_t  mode[3];
    uint8_t  bcd[3];
    uint64_t load_ns[3];        // wall-clock at last count (re)load (== d origin)
    uint64_t irq0_seen;         // # of ch0 periods already delivered as IRQ0
} pit_state_t;

static uint64_t now_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}

// QEMU `d`: elapsed PIT ticks since this channel's count was last loaded.
static uint32_t elapsed_d(pit_state_t* s, int ch) {
    uint64_t dt = now_ns() - s->load_ns[ch];
    return (uint32_t)((dt * PIT_FREQ) / 1000000000ull);
}

// pit_get_count (mirrors f_get_count): live count given d, count c, mode m.
static uint16_t get_count(uint8_t m, uint32_t c, uint32_t d) {
    switch (m) {
        case 0: case 1: case 4: case 5:
            return (uint16_t)(c - d);
        case 3: {
            uint64_t twod = (uint64_t)d * 2u;
            return (uint16_t)(c - (uint32_t)(twod % c));
        }
        default: // mode 2 (and 6/7)
            return (uint16_t)(c - (d % c));
    }
}

// pit_get_out (mirrors f_get_out): OUT bit given d, count c, mode m.
static int get_out(uint8_t m, uint32_t c, uint32_t d) {
    switch (m) {
        case 2: { uint32_t dmod = d % c; return (dmod == 0) && (d != 0); }
        case 3: { uint32_t dmod = d % c; uint32_t half = (c + 1) >> 1; return dmod < half; }
        case 4: case 5: return d == c;
        default: return d >= c;   // mode 0,1
    }
}

static uint32_t loadval(uint16_t v) { return v == 0 ? 0x10000u : v; }

static void pit_reset(ven_periph_t* p) {
    pit_state_t* s = (pit_state_t*)p->state;
    memset(s, 0, sizeof(*s));
    uint64_t t = now_ns();
    for (int i = 0; i < 3; i++) {
        s->count[i] = 0x10000u;   // pit_reset_common: mode=3, count=0x10000, d=0
        s->mode[i]  = 3;
        s->load_ns[i] = t;
    }
}

static uint8_t pit_read(ven_periph_t* p, uint16_t port) {
    pit_state_t* s = (pit_state_t*)p->state;
    int sel = port & 3;
    uint8_t r = 0;
    if (sel != 3) {
        uint16_t lc = s->latched_count[sel];
        uint16_t live = get_count(s->mode[sel], s->count[sel], elapsed_d(s, sel));
        if (s->status_latched[sel]) {
            r = s->status[sel];
            s->status_latched[sel] = 0;                     // read side-effect
        } else if (s->count_latched[sel] != 0) {
            switch (s->count_latched[sel]) {
                case RW_MSB:   r = lc >> 8;   s->count_latched[sel] = 0; break;
                case RW_WORD0: r = lc & 0xff; s->count_latched[sel] = RW_MSB; break;
                default:       r = lc & 0xff; s->count_latched[sel] = 0; break;  // RW_LSB
            }
        } else {
            switch (s->read_state[sel]) {
                case RW_MSB:   r = live >> 8; break;
                case RW_WORD1: r = live >> 8; s->read_state[sel] = RW_WORD0; break;
                case RW_WORD0: r = live & 0xff; s->read_state[sel] = RW_WORD1; break;
                default:       r = live & 0xff; break;       // RW_LSB
            }
        }
    }
    return r;
}

static void pit_write(ven_periph_t* p, uint16_t port, uint8_t val) {
    pit_state_t* s = (pit_state_t*)p->state;
    int sel = port & 3;
    if (sel == 3) {
        int ch = (val >> 6) & 3;
        int access = (val >> 4) & 3;
        if (ch == 3) {
            // read-back command
            for (int i = 0; i < 3; i++) {
                if (val & (1 << (1 + i))) {
                    if (!(val & 0x20) && s->count_latched[i] == 0) {        // latch count
                        s->latched_count[i] = get_count(s->mode[i], s->count[i], elapsed_d(s, i));
                        s->count_latched[i] = s->rw_mode[i];
                    }
                    if (!(val & 0x10) && !s->status_latched[i]) {           // latch status
                        s->status[i] = (uint8_t)((get_out(s->mode[i], s->count[i], elapsed_d(s, i)) << 7)
                                       | ((s->rw_mode[i] & 3) << 4) | (s->mode[i] << 1) | s->bcd[i]);
                        s->status_latched[i] = 1;
                    }
                }
            }
        } else if (access == 0) {
            // counter-latch command
            if (s->count_latched[ch] == 0) {
                s->latched_count[ch] = get_count(s->mode[ch], s->count[ch], elapsed_d(s, ch));
                s->count_latched[ch] = s->rw_mode[ch];
            }
        } else {
            s->rw_mode[ch]     = access;
            s->read_state[ch]  = access;
            s->write_state[ch] = access;
            s->mode[ch]        = (val >> 1) & 7;
            s->bcd[ch]         = val & 1;
        }
    } else {
        switch (s->write_state[sel]) {
            case RW_MSB:
                s->count[sel] = loadval((uint16_t)(val << 8));
                s->load_ns[sel] = now_ns();
                break;
            case RW_WORD0:
                s->write_latch[sel] = val;
                s->write_state[sel] = RW_WORD1;
                break;
            case RW_WORD1:
                s->count[sel] = loadval((uint16_t)((val << 8) | s->write_latch[sel]));
                s->load_ns[sel] = now_ns();
                s->write_state[sel] = RW_WORD0;
                break;
            default: // RW_LSB
                s->count[sel] = loadval(val);
                s->load_ns[sel] = now_ns();
                break;
        }
        if (sel == 0) s->irq0_seen = 0;   // ch0 reload restarts the IRQ0 period count
    }
}

static int pit_irq(ven_periph_t* p) {
    pit_state_t* s = (pit_state_t*)p->state;
    return get_out(s->mode[0], s->count[0], elapsed_d(s, 0));   // ch0 OUT == IRQ0 level
}

// PS pump helper: how many ch0 timer periods have completed since the last call —
// i.e. how many IRQ0 edges to deliver. Robust to slow polling (counts periods,
// not OUT edges, so a one-tick mode-2 pulse is never missed).
int ven_pit_irq0_ticks(ven_periph_t* p) {
    pit_state_t* s = (pit_state_t*)p->state;
    uint64_t periods = (uint64_t)elapsed_d(s, 0) / s->count[0];
    int n = (periods > s->irq0_seen) ? (int)(periods - s->irq0_seen) : 0;
    s->irq0_seen = periods;
    return n;
}

ven_periph_t* ven_pit_new(void) {
    ven_periph_t* p = (ven_periph_t*)calloc(1, sizeof(*p));
    p->state    = calloc(1, sizeof(pit_state_t));
    p->reset    = pit_reset;
    p->io_read  = pit_read;
    p->io_write = pit_write;
    p->irq      = pit_irq;
    pit_reset(p);
    return p;
}
