// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps_periph/ven_uart16550.c — PS C model of the NS16550A COM1 UART.
//
// A 1:1 behavioural port of rtl/soc/ven_uart16550.sv (qemu-grounded). Services
// 0x3F8-0x3FF when the UART is PS-placed; verified bit-exact vs qemu-system by
// run-soc-uart-gate.sh built with +VEN_UART_PS (the C model serves the port range
// instead of the RTL module). The RTL's clocked read side-effects become inline
// read side-effects here (the bridge calls io_read once per IN — same effect).

#include "ven_periph.h"
#include <stdlib.h>

typedef struct {
    uint8_t ier, lcr, mcr, lsr, msr, scr, fcr, dll, dlm, rbr;
} uart_state_t;

static void uart_reset(ven_periph_t* p) {
    uart_state_t* s = (uart_state_t*)p->state;
    s->ier = 0x00; s->lcr = 0x00; s->mcr = 0x08; s->lsr = 0x60; s->msr = 0xB0;
    s->scr = 0x00; s->fcr = 0x00; s->dll = 0x0C; s->dlm = 0x00; s->rbr = 0x00;
}

// IIR (read) — interrupt id + FIFO-enabled bits (mirrors the RTL always_comb).
static uint8_t uart_iir(const uart_state_t* s) {
    uint8_t iir = 0x01;  // no interrupt pending
    if      (s->ier & 0x04 && (s->lsr & 0x1E))      iir = 0x06;  // RX line status
    else if (s->ier & 0x01 && (s->lsr & 0x01))      iir = 0x04;  // RX data ready
    else if (s->ier & 0x02 && (s->lsr & 0x20))      iir = 0x02;  // THR empty
    else if (s->ier & 0x08 && (s->msr & 0x0F))      iir = 0x00;  // modem status
    if (s->fcr & 0x01) iir |= 0xC0;                              // FIFO enabled
    return iir;
}

static int uart_irq(ven_periph_t* p) {
    const uart_state_t* s = (uart_state_t*)p->state;
    return ((s->ier & 0x01) && (s->lsr & 0x01)) ||
           ((s->ier & 0x02) && (s->lsr & 0x20)) ||
           ((s->ier & 0x04) && (s->lsr & 0x1E)) ||
           ((s->ier & 0x08) && (s->msr & 0x0F));
}

static uint8_t uart_read(ven_periph_t* p, uint16_t port) {
    uart_state_t* s = (uart_state_t*)p->state;
    int off = port & 7, dlab = s->lcr & 0x80;
    uint8_t v;
    switch (off) {
        case 0: v = dlab ? s->dll : s->rbr; if (!dlab) s->lsr &= ~0x01; break; // RBR clears DR
        case 1: v = dlab ? s->dlm : s->ier; break;
        case 2: v = uart_iir(s); break;
        case 3: v = s->lcr; break;
        case 4: v = s->mcr; break;
        case 5: v = s->lsr; s->lsr &= ~0x1E; break;   // LSR read clears error/break bits
        case 6: v = s->msr; s->msr &= ~0x0F; break;   // MSR read clears delta bits
        default: v = s->scr; break;                    // case 7
    }
    return v;
}

static void uart_write(ven_periph_t* p, uint16_t port, uint8_t val) {
    uart_state_t* s = (uart_state_t*)p->state;
    int off = port & 7, dlab = s->lcr & 0x80;
    switch (off) {
        case 0: if (dlab) s->dll = val; /* else THR: transmit (instant, THRE stays) */ break;
        case 1: if (dlab) s->dlm = val; else s->ier = val & 0x0F; break;
        case 2: s->fcr = val; break;
        case 3: s->lcr = val; break;
        case 4: s->mcr = val & 0x1F; break;
        case 5: case 6: break;                         // LSR/MSR read-only
        default: s->scr = val; break;                  // case 7
    }
}

ven_periph_t* ven_uart16550_new(void) {
    ven_periph_t* p = (ven_periph_t*)calloc(1, sizeof(ven_periph_t));
    p->state    = calloc(1, sizeof(uart_state_t));
    p->reset    = uart_reset;
    p->io_read  = uart_read;
    p->io_write = uart_write;
    p->irq      = uart_irq;
    uart_reset(p);
    return p;
}
