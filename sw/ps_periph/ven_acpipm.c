// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps_periph/ven_acpipm.c — PS C model of the ACPI PM Timer (PIIX4 PM base+0x08).
//
// A 1:1 behavioural port of rtl/soc/ven_acpipm.sv (qemu-grounded). Services port
// 0x608 when the ACPI PM timer is PS-placed. The device is a free-running 24-bit
// counter that ticks at PM_TIMER_FREQUENCY; an IN at 0x608 returns the addr-selected
// byte of {8'h00, count[23:0]}, and an OUT at 0x608 is IGNORED (qemu
// acpi_pm_tmr_write does nothing — modeled here as an inert write).
//
// ORACLE BOUNDARY (per the RTL header, lines 36-48): the *instantaneous* count value
// at a given cycle is NOT oracled vs qemu (qemu samples a host virtual clock; the RTL
// samples clk; this model has no clock). Only the CPU-observable PROPERTIES are checked:
//   (a) 24-bit width / wrap  (value & 0x00FFFFFF, bit 24+ never visible),
//   (b) monotonic increase between reads,
//   (c) writes ignored,
//   (d) average rate == PM_TIMER_FREQUENCY (a structural cadence, not oracled).
// The RTL advances count_q on a fractional-accumulator `tick` derived from clk. This
// PS model is driven by io_read calls (it sees no clock), so to preserve the oracled
// monotonic-increase property it ticks the counter once per READ access — the same
// CPU-visible contract (a strictly-increasing 24-bit value), within the oracle bound
// (the exact value/rate is not compared). The byte view mirrors the RTL addr[1:0]
// decode of {8'h00, count[23:0]}.

#include "ven_periph.h"
#include <stdlib.h>

typedef struct {
    uint32_t count;   // free-running 24-bit ACPI PM counter (count_q; low 24 bits used)
} acpipm_state_t;

static void acpipm_reset(ven_periph_t* p) {
    acpipm_state_t* s = (acpipm_state_t*)p->state;
    s->count = 0x000000;   // RTL reset: count_q <= 24'h000000 (acpi_pm_tmr_reset starts at 0)
}

// IN: combinational off the counter register. The native dword value is
// {8'h00, count[23:0]} for ANY addr; the byte view selects a byte by addr[1:0].
// The RTL ticks count_q on a clk-derived `tick`; here we tick once per read to keep
// the value monotonically increasing between reads (the oracled property), wrapping
// at 2^24 (== d & 0xffffff).
static uint8_t acpipm_read(ven_periph_t* p, uint16_t port) {
    acpipm_state_t* s = (acpipm_state_t*)p->state;
    uint32_t tmr_val = s->count & 0x00FFFFFFu;   // == acpi_pm_tmr_get() & 0xffffff
    uint8_t v;
    switch (port & 0x3) {
        case 0:  v = (uint8_t)(tmr_val        & 0xFFu); break;  // count[7:0]
        case 1:  v = (uint8_t)((tmr_val >> 8)  & 0xFFu); break; // count[15:8]
        case 2:  v = (uint8_t)((tmr_val >> 16) & 0xFFu); break; // count[23:16]
        default: v = (uint8_t)((tmr_val >> 24) & 0xFFu); break; // 8'h00 (count[31:24])
    }
    // tick: free-running 24-bit counter advances (wraps at 2^24). Monotonic between reads.
    s->count = (s->count + 1u) & 0x00FFFFFFu;
    return v;
}

// OUT: IGNORED. qemu acpi_pm_tmr_write does nothing; the RTL deliberately gives
// (cs & we) no effect on count_q. Modeled explicitly as an inert write.
static void acpipm_write(ven_periph_t* p, uint16_t port, uint8_t val) {
    (void)p; (void)port; (void)val;   // write data ignored by this device
}

// No IRQ / SCI in the boot path — the RTL provides no IRQ output. Report "no line".
static int acpipm_irq(ven_periph_t* p) {
    (void)p;
    return -1;
}

ven_periph_t* ven_acpipm_new(void) {
    ven_periph_t* p = (ven_periph_t*)calloc(1, sizeof(ven_periph_t));
    p->state    = calloc(1, sizeof(acpipm_state_t));
    p->reset    = acpipm_reset;
    p->io_read  = acpipm_read;
    p->io_write = acpipm_write;
    p->irq      = acpipm_irq;
    acpipm_reset(p);
    return p;
}
