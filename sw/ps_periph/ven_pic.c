// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps_periph/ven_pic.c — PS C model of the cascaded dual Intel 8259A PIC.
//
// A 1:1 behavioural port of rtl/soc/ven_pic.sv, which is itself matched
// bit-for-bit to QEMU 8.2.2 hw/intc/i8259.c + i8259_common.c (get_priority,
// pic_get_irq, pic_update_irq, pic_set_irq, pic_intack, pic_read_irq,
// pic_ioport_write/read, elcr_ioport_write/read, pic_reset). Master at
// 0x20/0x21, slave at 0xA0/0xA1, ELCR at 0x4D0/0x4D1; slave INT cascades onto
// master IR2.
//
// On the board this is the F3 interrupt path: devices (the i8042 C model, a
// future PIT) drive ven_pic_set_irq(); the master INT level (vtable irq()) and
// the would-be INTA vector (ven_pic_peek_vector) are mirrored into the
// ven_soc_axil R_INTR seam; when the core's inta strobe is observed
// (R_INTR.INTA_SEEN), the PS calls ven_pic_intack() — the exact pic_read_irq()
// state mutation the RTL applies on its inta input.
//
// The RTL's per-clock cascade resample (set_irq(M, 2, slave INT)) becomes a
// cascade refresh after every state mutation here — same fixed point, since
// the chip state only changes through these entry points.
//
// NOTE: like every sw/ps_periph model this file must compile as BOTH C (A53
// firmware, gcc) and C++ (the tb_soc gate build, g++) — keep it dual-valid.

#include "ven_periph.h"
#include <stdlib.h>

// per-chip state (mirrors ven_pic.sv / QEMU PICCommonState)
typedef struct {
    uint8_t irr, imr, isr, last_irr;
    uint8_t prio_add;     // 0..7
    uint8_t irq_base;
    uint8_t rr_sel;       // read_reg_select (0=IRR, 1=ISR)
    uint8_t poll;
    uint8_t spec_mask;
    uint8_t init_st;      // init_state 0..3
    uint8_t auto_eoi, rot_aeoi, sfnm, init4, single_md;
    uint8_t elcr, ltim;
} pic_chip_t;

typedef struct {
    pic_chip_t c[2];      // [0]=master, [1]=slave
} pic_state_t;

#define PIC_M 0
#define PIC_S 1

// ELCR write masks (QEMU i8259_init_chip): master 0xf8, slave 0xde.
#define ELCR_MASK_M 0xF8u
#define ELCR_MASK_S 0xDEu

// get_priority(s, mask): highest priority in mask, 8 if none.
static int pic_get_priority(const pic_chip_t* c, uint8_t mask) {
    int p;
    if (mask == 0) return 8;
    p = 0;
    while ((mask & (1u << ((p + c->prio_add) & 7))) == 0) p++;
    return p;
}

// pic_get_irq(s): the IRQ the chip wants to deliver, -1 if none. NB: sfnm only
// ignores the cascade ISR bit on the MASTER (QEMU guards s == isa_pic; the RTL
// guards `sfnm && ci==M`), hence the chip index parameter.
static int pic_get_irq_chip(const pic_state_t* s, int ci) {
    const pic_chip_t* c = &s->c[ci];
    uint8_t mask = (uint8_t)(c->irr & ~c->imr);
    int prio, cur_prio;
    prio = pic_get_priority(c, mask);
    if (prio == 8) return -1;
    mask = c->isr;
    if (c->spec_mask)              mask = (uint8_t)(mask & ~c->imr);
    if (c->sfnm && ci == PIC_M)    mask = (uint8_t)(mask & ~(1u << 2));
    cur_prio = pic_get_priority(c, mask);
    if (prio < cur_prio) return (prio + c->prio_add) & 7;
    return -1;
}

static int pic_chip_output(const pic_state_t* s, int ci) {
    return pic_get_irq_chip(s, ci) >= 0;
}

// pic_set_irq with edge/level (ELCR) detection — mirrors RTL set_irq().
static void pic_set_irq_chip(pic_chip_t* c, int irqn, int level) {
    uint8_t mask = (uint8_t)(1u << irqn);
    if (c->ltim || (c->elcr & mask)) {
        // level triggered
        if (level) { c->irr |= mask;             c->last_irr |= mask; }
        else       { c->irr = (uint8_t)(c->irr & ~mask); c->last_irr = (uint8_t)(c->last_irr & ~mask); }
    } else {
        // edge triggered
        if (level) {
            if ((c->last_irr & mask) == 0) c->irr |= mask;
            c->last_irr |= mask;
        } else {
            c->last_irr = (uint8_t)(c->last_irr & ~mask);
        }
    }
}

// cascade: master IR2 mirrors the slave INT output level (QEMU wires slave INT
// to master IR2; the RTL resamples this every clock — we refresh it after every
// mutation, reaching the same fixed point).
static void pic_update_cascade(pic_state_t* s) {
    pic_set_irq_chip(&s->c[PIC_M], 2, pic_chip_output(s, PIC_S));
}

// pic_intack() — set ISR / clear IRR / AEOI rotate, for one chip+irq.
static void pic_do_intack(pic_chip_t* c, int irqn) {
    if (c->auto_eoi) {
        if (c->rot_aeoi) c->prio_add = (uint8_t)((irqn + 1) & 7);
    } else {
        c->isr |= (uint8_t)(1u << irqn);
    }
    // don't clear a level-sensitive interrupt
    if (!c->ltim && ((c->elcr & (1u << irqn)) == 0))
        c->irr = (uint8_t)(c->irr & ~(1u << irqn));
}

// pic_init_reset -> pic_reset_common (ICW1 path: elcr/ltim PRESERVED).
static void pic_init_reset(pic_chip_t* c) {
    c->last_irr = 0;
    c->irr      = (uint8_t)(c->irr & c->elcr);
    c->imr = 0; c->isr = 0;
    c->prio_add = 0; c->irq_base = 0;
    c->rr_sel = 0; c->poll = 0; c->spec_mask = 0;
    c->init_st = 0; c->auto_eoi = 0; c->rot_aeoi = 0;
    c->sfnm = 0; c->init4 = 0; c->single_md = 0;
}

// command-port write (0x20/0xA0): ICW1 / OCW2 / OCW3 — pic_ioport_write addr==0.
static void pic_wr_cmd(pic_chip_t* c, uint8_t val) {
    if (val & 0x10u) {
        // ICW1
        pic_init_reset(c);
        c->init_st   = 1;
        c->init4     = (uint8_t)(val & 1u);
        c->single_md = (uint8_t)((val >> 1) & 1u);
        c->ltim      = (uint8_t)((val >> 3) & 1u);
    } else if (val & 0x08u) {
        // OCW3
        if (val & 0x04u) c->poll      = 1;
        if (val & 0x02u) c->rr_sel    = (uint8_t)(val & 1u);
        if (val & 0x40u) c->spec_mask = (uint8_t)((val >> 5) & 1u);
    } else {
        // OCW2
        int cmd = val >> 5;
        int prio, irqn;
        switch (cmd) {
            case 0: case 4:
                c->rot_aeoi = (uint8_t)(cmd >> 2);
                break;
            case 1: case 5:  // (rotate on) non-specific EOI
                prio = pic_get_priority(c, c->isr);
                if (prio != 8) {
                    irqn = (prio + c->prio_add) & 7;
                    c->isr = (uint8_t)(c->isr & ~(1u << irqn));
                    if (cmd == 5) c->prio_add = (uint8_t)((irqn + 1) & 7);
                }
                break;
            case 3:          // specific EOI
                irqn = val & 7;
                c->isr = (uint8_t)(c->isr & ~(1u << irqn));
                break;
            case 6:          // set priority (rotate)
                c->prio_add = (uint8_t)(((val & 7) + 1) & 7);
                break;
            case 7:          // rotate on specific EOI
                irqn = val & 7;
                c->isr = (uint8_t)(c->isr & ~(1u << irqn));
                c->prio_add = (uint8_t)((irqn + 1) & 7);
                break;
            default:         // 2: no operation
                break;
        }
    }
}

// data-port write (0x21/0xA1): OCW1 (IMR) or the ICW2..4 init sequence.
static void pic_wr_data(pic_chip_t* c, uint8_t val) {
    switch (c->init_st) {
        case 0: c->imr = val; break;                     // OCW1
        case 1:                                          // ICW2: vector base
            c->irq_base = (uint8_t)(val & 0xF8u);
            c->init_st  = c->single_md ? (c->init4 ? 3 : 0) : 2;
            break;
        case 2:                                          // ICW3 (cascade map, ignored)
            c->init_st = c->init4 ? 3 : 0;
            break;
        case 3:                                          // ICW4
            c->sfnm     = (uint8_t)((val >> 4) & 1u);
            c->auto_eoi = (uint8_t)((val >> 1) & 1u);
            c->init_st  = 0;
            break;
        default: break;
    }
}

// ---- vtable entry points ---------------------------------------------------

static void pic_reset(ven_periph_t* p) {
    pic_state_t* s = (pic_state_t*)p->state;
    int i;
    for (i = 0; i < 2; i++) {
        s->c[i].elcr = 0; s->c[i].ltim = 0;   // pic_reset: elcr/ltim cleared too
        pic_init_reset(&s->c[i]);
    }
}

// combinational read + the poll-mode intack read side-effect, fused (the bridge
// calls io_read exactly once per IN, same contract as ven_i8042.c).
static uint8_t pic_io_read(ven_periph_t* p, uint16_t port) {
    pic_state_t* s = (pic_state_t*)p->state;
    pic_chip_t*  c;
    int ci, data_port, irq;
    uint8_t v;

    if (port == 0x4D0) return s->c[PIC_M].elcr;
    if (port == 0x4D1) return s->c[PIC_S].elcr;
    if (port != 0x20 && port != 0x21 && port != 0xA0 && port != 0xA1) return 0x00;

    ci = (port & 0x80) ? PIC_S : PIC_M;     // 0xA0/0xA1 -> slave
    data_port = port & 1;
    c = &s->c[ci];

    if (c->poll) {
        // poll-mode read: returns (irq | 0x80) or 0, AND consumes it (intack).
        irq = pic_get_irq_chip(s, ci);
        if (irq >= 0) {
            v = (uint8_t)(irq | 0x80u);
            pic_do_intack(c, irq);
        } else {
            v = 0x00;
        }
        c->poll = 0;
        pic_update_cascade(s);
        return v;
    }
    if (!data_port) return c->rr_sel ? c->isr : c->irr;
    return c->imr;
}

static void pic_io_write(ven_periph_t* p, uint16_t port, uint8_t val) {
    pic_state_t* s = (pic_state_t*)p->state;
    switch (port) {
        case 0x20:  pic_wr_cmd (&s->c[PIC_M], val); break;
        case 0x21:  pic_wr_data(&s->c[PIC_M], val); break;
        case 0xA0:  pic_wr_cmd (&s->c[PIC_S], val); break;
        case 0xA1:  pic_wr_data(&s->c[PIC_S], val); break;
        case 0x4D0: s->c[PIC_M].elcr = (uint8_t)(val & ELCR_MASK_M); break;
        case 0x4D1: s->c[PIC_S].elcr = (uint8_t)(val & ELCR_MASK_S); break;
        default: return;
    }
    pic_update_cascade(s);
}

// master INT output level (-> the core's intr pin via R_INTR.ASSERT).
static int pic_irq(ven_periph_t* p) {
    pic_state_t* s = (pic_state_t*)p->state;
    pic_update_cascade(s);                  // refresh IR2 from the slave output
    return pic_chip_output(s, PIC_M);
}

// ---- F3 extras (not in the generic vtable) ----------------------------------

// device IRQ line 0..15 -> the PIC inputs (slave lines are 8..15; line 2 is the
// internal cascade and is ignored, exactly like irq_in[2] in the RTL).
void ven_pic_set_irq(ven_periph_t* p, int irq, int level) {
    pic_state_t* s = (pic_state_t*)p->state;
    if (irq < 0 || irq > 15 || irq == 2) return;
    if (irq < 8) pic_set_irq_chip(&s->c[PIC_M], irq, level);
    else         pic_set_irq_chip(&s->c[PIC_S], irq - 8, level);
    pic_update_cascade(s);
}

// the vector an INTA would return RIGHT NOW, with NO state change (mirrors the
// RTL's combinational inta_vector). The PS stages this into R_INTR.
uint8_t ven_pic_peek_vector(ven_periph_t* p) {
    pic_state_t* s = (pic_state_t*)p->state;
    int mi, si;
    pic_update_cascade(s);
    mi = pic_get_irq_chip(s, PIC_M);
    if (mi < 0)  return (uint8_t)(s->c[PIC_M].irq_base + 7);   // spurious master IR7
    if (mi != 2) return (uint8_t)(s->c[PIC_M].irq_base + mi);
    si = pic_get_irq_chip(s, PIC_S);
    if (si < 0)  return (uint8_t)(s->c[PIC_S].irq_base + 7);   // spurious slave IR7
    return (uint8_t)(s->c[PIC_S].irq_base + si);
}

// pic_read_irq(): the INTA-boundary state mutation + the delivered vector. The
// PS calls this when the core's inta strobe is observed (R_INTR.INTA_SEEN) —
// the same side-effects the RTL applies on its `inta` input.
uint8_t ven_pic_intack(ven_periph_t* p) {
    pic_state_t* s = (pic_state_t*)p->state;
    int mi, si;
    uint8_t vec;
    pic_update_cascade(s);
    mi = pic_get_irq_chip(s, PIC_M);
    if (mi >= 0) {
        if (mi == 2) {
            si = pic_get_irq_chip(s, PIC_S);
            if (si >= 0) {
                pic_do_intack(&s->c[PIC_S], si);
                vec = (uint8_t)(s->c[PIC_S].irq_base + si);
            } else {
                vec = (uint8_t)(s->c[PIC_S].irq_base + 7);     // spurious slave
            }
            pic_do_intack(&s->c[PIC_M], 2);
        } else {
            pic_do_intack(&s->c[PIC_M], mi);
            vec = (uint8_t)(s->c[PIC_M].irq_base + mi);
        }
    } else {
        vec = (uint8_t)(s->c[PIC_M].irq_base + 7);             // spurious master
    }
    pic_update_cascade(s);
    return vec;
}

ven_periph_t* ven_pic_new(void) {
    ven_periph_t* p = (ven_periph_t*)calloc(1, sizeof(ven_periph_t));
    p->state    = calloc(1, sizeof(pic_state_t));
    p->reset    = pic_reset;
    p->io_read  = pic_io_read;
    p->io_write = pic_io_write;
    p->irq      = pic_irq;
    pic_reset(p);
    return p;
}
