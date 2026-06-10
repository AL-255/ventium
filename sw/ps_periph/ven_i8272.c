// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps_periph/ven_i8272.c — PS C model of the 82077/8272A floppy controller.
//
// A 1:1 behavioural port of rtl/soc/ven_i8272.sv (qemu-grounded, QEMU 8.2.2
// hw/block/fdc.c). Services the SYNCHRONOUS register surface at I/O 0x3F0-0x3F5
// + 0x3F7 (NOT 0x3F6 = IDE alt-status) when the FDC is PS-placed; verified
// bit-exact vs qemu-system by the psocfdc gate built with +VEN_I8272_PS (the C
// model serves the port range instead of the RTL module).
//
// The RTL's clocked read side-effects (the result-FIFO advance) become inline
// read side-effects here: the bridge calls io_read once per IN, mirroring the
// RTL combinational read (returns fifo[dpos] BEFORE the clock edge advances it).
//
// ORACLE BOUNDARY (excluded — needs disk/DMA or async seek timing): READ/WRITE/
// FORMAT/READ-ID/RECALIBRATE/SEEK, the DIR media-change bit, motor spin-up. The
// IRQ6 raised on reset-release is wired out (quiescent on the diff: CLI).

#include "ven_periph.h"
#include <stdlib.h>

typedef struct {
    uint8_t  sra, srb, dor, tdr, dsr, msr, ccr, dir;
    uint8_t  cur_drv;                 // [1:0]
    uint8_t  config_reg, precomp, perp, lock;
    uint8_t  status0;                 // ST0 base after reset
    uint8_t  reset_sensei;            // [2:0] post-reset 4-drive SENSE INT poll counter
    uint8_t  intpend;                 // interrupt pending (cleared by result read)
    uint8_t  fifo[16];
    uint8_t  dpos, dlen;              // [3:0] position + expected length
    uint8_t  phase_res;              // 0 = command phase, 1 = result phase
    uint8_t  cmd_op;                 // the command opcode (fifo[0])
} fdc_state_t;

// command total length (bytes incl. the opcode) for supported cmds.
static uint8_t cmd_clen(uint8_t op) {
    if ((op & 0x7F) == 0x14) return 1;  // LOCK (bit7 = lock flag)
    switch (op) {
        case 0x08: return 1;            // SENSE INTERRUPT STATUS
        case 0x10: return 1;            // VERSION
        case 0x18: return 1;            // PART ID
        case 0x03: return 3;            // SPECIFY  (cmd + 2)
        case 0x13: return 4;            // CONFIGURE (cmd + 3)
        case 0x12: return 2;            // PERPENDICULAR (cmd + 1)
        default:   return 1;            // INVALID -> immediate 1-byte result
    }
}

static void fdc_reset(ven_periph_t* p) {
    fdc_state_t* s = (fdc_state_t*)p->state;
    s->sra = 0x00; s->srb = 0xC0; s->dor = 0x0C; s->tdr = 0x00; s->dsr = 0x00;
    s->msr = 0x80; s->ccr = 0x00; s->dir = 0x00; s->cur_drv = 0x00;
    s->config_reg = 0x00; s->precomp = 0x00; s->perp = 0x00; s->lock = 0x00;
    s->status0 = 0x00; s->reset_sensei = 0x00; s->intpend = 0x00;
    s->dpos = 0x00; s->dlen = 0x01; s->phase_res = 0x00; s->cmd_op = 0x00;
}

static int fdc_irq(ven_periph_t* p) {
    const fdc_state_t* s = (fdc_state_t*)p->state;
    return s->intpend ? 1 : 0;            // assign irq = intpend
}

static uint8_t fdc_read(ven_periph_t* p, uint16_t port) {
    fdc_state_t* s = (fdc_state_t*)p->state;
    int off = port & 7;
    uint8_t v;
    switch (off) {
        case 1: v = s->sra; break;
        case 2: v = (uint8_t)(s->dor | s->cur_drv); break;   // DOR read = dor | cur_drv
        case 3: v = s->tdr; break;
        case 4: v = s->msr; break;
        case 5:                                              // FIFO result byte
            v = s->phase_res ? s->fifo[s->dpos & 0x0F] : 0x00;
            // result-phase read side effect (RTL clocked CPU-IN branch)
            if (s->phase_res) {
                if (((s->dpos + 1) & 0x0F) == s->dlen) {
                    s->phase_res = 0; s->dlen = 1; s->dpos = 0; s->msr = 0x80;
                    s->intpend = 0;                          // reset_irq: clear pending
                } else {
                    s->dpos = (uint8_t)((s->dpos + 1) & 0x0F); // MSR stays 0xD0
                }
            }
            break;
        case 7: v = s->dir; break;
        default: v = 0xFF; break;                            // SRA-aliased / undecoded
    }
    return v;
}

static void fdc_write(ven_periph_t* p, uint16_t port, uint8_t val) {
    fdc_state_t* s = (fdc_state_t*)p->state;
    int off = port & 7;
    switch (off) {
        case 2: // DOR: a 0->1 transition on bit2 (/RESET) runs the controller reset
            if ((val & 0x04) && !(s->dor & 0x04)) {
                // fdctrl_reset(do_irq=1): RDYCHG on all drives, RQM ready, 4-drive sensei
                s->msr = 0x80; s->phase_res = 0; s->dpos = 0; s->dlen = 1;
                s->status0 = 0xC0; s->reset_sensei = 4; s->intpend = 1;
            }
            s->dor = val;
            s->cur_drv = (uint8_t)(val & 0x03);
            break;
        case 3: s->tdr = val; break;
        case 4: s->dsr = val; break;
        case 7: s->ccr = val; break;
        case 5: { // command/result FIFO; write only valid in command phase
            if (!s->phase_res) {
                uint8_t op, sidx;
                // effective command length: on the first byte use the just-written opcode.
                uint8_t eff_clen = (s->dpos == 0) ? cmd_clen(val) : s->dlen;
                int cmd_last = ((s->dpos + 1) & 0x0F) == eff_clen;
                s->fifo[s->dpos & 0x0F] = val;
                if (s->dpos == 0) { s->cmd_op = val; s->dlen = cmd_clen(val); }
                op   = (s->dpos == 0) ? val : s->cmd_op;     // the command opcode
                sidx = (uint8_t)(4 - s->reset_sensei);       // post-reset drive poll index 0..3
                if (cmd_last) {
                    // ---- run the command handler synchronously ----
                    if ((op & 0x7F) == 0x14) {               // LOCK (0x14/0x94): result = flag<<4
                        s->lock = (uint8_t)((op >> 7) & 0x01);
                        s->fifo[0] = (op & 0x80) ? 0x10 : 0x00;
                        s->phase_res = 1; s->dlen = 1; s->dpos = 0; s->msr = 0xD0;
                    } else switch (op) {
                        case 0x08: // SENSE INTERRUPT STATUS (post-reset 4-drive polling)
                            s->fifo[0] = (s->reset_sensei != 0)
                                       ? (uint8_t)(0xC0 | (sidx & 0x03))
                                       : (s->intpend ? (uint8_t)(s->status0 | s->cur_drv) : 0x80);
                            s->fifo[1] = 0x00;               // PCN (track) = 0
                            if (s->reset_sensei != 0) s->reset_sensei--;
                            s->phase_res = 1; s->dlen = 2; s->dpos = 0; s->msr = 0xD0;
                            break;
                        case 0x10: s->fifo[0] = 0x90; s->phase_res = 1; s->dlen = 1; s->dpos = 0; s->msr = 0xD0; break; // VERSION
                        case 0x18: s->fifo[0] = 0x41; s->phase_res = 1; s->dlen = 1; s->dpos = 0; s->msr = 0xD0; break; // PART ID
                        case 0x03: s->phase_res = 0; s->dlen = 1; s->dpos = 0; s->msr = 0x80; break;                    // SPECIFY
                        case 0x13: s->config_reg = s->fifo[2]; s->precomp = val;                                        // CONFIGURE
                                   s->phase_res = 0; s->dlen = 1; s->dpos = 0; s->msr = 0x80; break;
                        case 0x12: if (val & 0x80) s->perp = (uint8_t)(val & 0x07);                                     // PERPENDICULAR
                                   s->phase_res = 0; s->dlen = 1; s->dpos = 0; s->msr = 0x80; break;
                        default:   s->fifo[0] = 0x80; s->phase_res = 1; s->dlen = 1; s->dpos = 0; s->msr = 0xD0; break;  // INVALID -> ST0.INVCMD
                    }
                } else {
                    s->dpos = (uint8_t)((s->dpos + 1) & 0x0F);
                    s->msr = 0x90;                           // RQM|CB: accumulating a multi-byte command
                }
            }
            break;
        }
        default: break; // SRA/SRB read-only ports: writes ignored
    }
}

ven_periph_t* ven_i8272_new(void) {
    ven_periph_t* p = (ven_periph_t*)calloc(1, sizeof(ven_periph_t));
    p->state    = calloc(1, sizeof(fdc_state_t));
    p->reset    = fdc_reset;
    p->io_read  = fdc_read;
    p->io_write = fdc_write;
    p->irq      = fdc_irq;
    fdc_reset(p);
    return p;
}
