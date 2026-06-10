// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps_periph/ven_i8042.c — PS C model of the Intel 8042 PS/2 controller.
//
// A 1:1 behavioural port of rtl/soc/ven_i8042.sv (qemu-grounded vs pckbd.c).
// Services 0x60/0x64 when the i8042 is PS-placed; mirrors the RTL's CPU-visible
// register read/write logic byte-for-byte. The RTL's clocked read side-effect at
// 0x60 (kbd_read_data: dequeue OBF + deassert IRQ) becomes an inline read
// side-effect here — the bridge calls io_read EXACTLY ONCE per IN, same effect.
//
// ORACLE BOUNDARY: the keyboard/mouse PS/2 device queues (host-clock, async) are
// NOT modeled, exactly as in the RTL. The controller-sourced OBF path (cbdata)
// and the queue-independent A20 / outport / mode / status surface ARE modeled,
// returning the same bytes the RTL ven_i8042 returns. The psocdev test exercises
// only the queue-independent A20 commands (0xDF/0xDD via 0x64) + the outport.

#include "ven_periph.h"
#include <stdlib.h>

// Status register bits (STAT_*) — pckbd.c lines 86-103
#define STAT_OBF        0x01u  // output buffer full
#define STAT_SELFTEST   0x04u  // system flag (SYS)
#define STAT_CMD        0x08u  // last write was command (0=data)
#define STAT_UNLOCKED   0x10u  // keyboard unlocked
#define STAT_MOUSE_OBF  0x20u  // mouse output buffer full

// Mode / command-byte bits (MODE_*) — pckbd.c lines 105-121
#define MODE_KBD_INT        0x01u
#define MODE_MOUSE_INT      0x02u
#define MODE_DISABLE_KBD    0x10u
#define MODE_DISABLE_MOUSE  0x20u

// Output-port bits (OUT_*) — pckbd.c lines 123-134
#define OUT_RESET      0x01u  // 1=normal, 0=reset
#define OUT_A20        0x02u
#define OUT_OBF        0x10u
#define OUT_MOUSE_OBF  0x20u
#define OUT_ONES       0xccu  // default high bits (pckbd.c:134)

// Controller commands (CMD_*) — pckbd.c lines 42-84
#define CMD_READ_MODE      0x20u
#define CMD_WRITE_MODE     0x60u
#define CMD_MOUSE_DISABLE  0xA7u
#define CMD_MOUSE_ENABLE   0xA8u
#define CMD_TEST_MOUSE     0xA9u
#define CMD_SELF_TEST      0xAAu
#define CMD_KBD_TEST       0xABu
#define CMD_KBD_DISABLE    0xADu
#define CMD_KBD_ENABLE     0xAEu
#define CMD_READ_INPORT    0xC0u
#define CMD_READ_OUTPORT   0xD0u
#define CMD_WRITE_OUTPORT  0xD1u
#define CMD_WRITE_OBUF     0xD2u
#define CMD_WRITE_AUX_OBUF 0xD3u
#define CMD_WRITE_MOUSE    0xD4u
#define CMD_DISABLE_A20    0xDDu
#define CMD_ENABLE_A20     0xDFu
#define CMD_PULSE_3_0      0xF0u  // 0xF0-0xFF mask
#define CMD_RESET          0xFEu
#define CMD_NO_OP          0xFFu

typedef struct {
    uint8_t status;     // status register (read at 0x64)
    uint8_t mode;       // mode / command byte
    uint8_t outport;    // output port P2
    uint8_t write_cmd;  // pending controller command awaiting a 0x60 data byte
    uint8_t cbdata;     // controller-sourced output buffer (the "cbdata" path)
    uint8_t obdata;     // last byte handed to the CPU at 0x60
} i8042_state_t;

// kbd_reset(): mode = KBD_INT|MOUSE_INT, status = CMD|UNLOCKED,
// outport = RESET|A20|ONES, pending cleared, OBF deasserted.
static void i8042_reset(ven_periph_t* p) {
    i8042_state_t* s = (i8042_state_t*)p->state;
    s->mode      = (uint8_t)(MODE_KBD_INT | MODE_MOUSE_INT);     // 0x03
    s->status    = (uint8_t)(STAT_CMD | STAT_UNLOCKED);          // 0x18
    s->outport   = (uint8_t)(OUT_RESET | OUT_A20 | OUT_ONES);    // 0xCF
    s->write_cmd = 0x00u;
    s->cbdata    = 0x00u;
    s->obdata    = 0x00u;
}

// Normalize the 0xF0-0xFF "pulse output port bits 3-0" command (pckbd.c
// 329-335): if (val & 0xF0)==0xF0, then bit0 low => RESET, else => NO_OP.
static uint8_t i8042_normalize_cmd(uint8_t v) {
    if ((v & CMD_PULSE_3_0) == CMD_PULSE_3_0)
        return ((v & 0x01u) == 0u) ? CMD_RESET : CMD_NO_OP;
    return v;
}

// IRQ line generation (mirrors the RTL combinational irq1: kbd IRQ1 level).
//   irq_kbd = OBF & ~MOUSE_OBF & MODE_KBD_INT & ~MODE_DISABLE_KBD
// The single-line vtable surfaces the keyboard IRQ1; mouse IRQ12 (OBF &
// MOUSE_OBF & MODE_MOUSE_INT) is part of the same combinational rule in RTL but
// is not consulted on the PS io-bridge path.
static int i8042_irq(ven_periph_t* p) {
    const i8042_state_t* s = (i8042_state_t*)p->state;
    if ((s->status & STAT_OBF) != 0u && (s->status & STAT_MOUSE_OBF) == 0u &&
        (s->mode & MODE_KBD_INT) != 0u && (s->mode & MODE_DISABLE_KBD) == 0u)
        return 1;
    return 0;
}

// Combinational read (rdata) + the clocked read side-effect at 0x60, fused.
// The bridge calls io_read once per IN, so the RTL's clocked dequeue commits
// inline here.
//   read 0x64 (cmd/status, addr[2]=1) -> status (no side effect)
//   read 0x60 (data,       addr[2]=0) -> OBF? cbdata : obdata; then if OBF set,
//                                        dequeue (latch obdata, clear OBF in
//                                        status + outport).
static uint8_t i8042_read(ven_periph_t* p, uint16_t port) {
    i8042_state_t* s = (i8042_state_t*)p->state;
    int is_cmd_port = (port >> 2) & 1;  // addr[2]: 1 => 0x64, 0 => 0x60
    uint8_t v;
    if (is_cmd_port) {
        v = s->status;  // read of 0x64 (status): no side effect
    } else {
        // data port: rdata is the to-be-dequeued byte (cbdata) when OBF set,
        // else the stale last obdata (QEMU: s->obdata).
        if ((s->status & STAT_OBF) != 0u) {
            v = s->cbdata;
            // kbd_read_data side effect: dequeue + deassert IRQ.
            s->obdata  = s->cbdata;
            s->status  = (uint8_t)(s->status  & ~(STAT_OBF | STAT_MOUSE_OBF));
            s->outport = (uint8_t)(s->outport & ~(OUT_OBF | OUT_MOUSE_OBF));
        } else {
            v = s->obdata;
        }
    }
    return v;
}

static void i8042_write(ven_periph_t* p, uint16_t port, uint8_t val) {
    i8042_state_t* s = (i8042_state_t*)p->state;
    int is_cmd_port = (port >> 2) & 1;  // addr[2]: 1 => 0x64, 0 => 0x60

    if (is_cmd_port) {
        // WRITE to 0x64 (command). Base: status bit3 (CMD) reflects last-write-
        // was-cmd; OBF-queueing commands then overwrite status (NB last-write
        // wins in the RTL always_ff).
        uint8_t ncmd = i8042_normalize_cmd(val);
        s->status = (uint8_t)(s->status | STAT_CMD);
        switch (ncmd) {
            case CMD_READ_MODE:
                s->cbdata  = s->mode;
                s->status  = (uint8_t)((s->status | STAT_CMD | STAT_OBF) & ~STAT_MOUSE_OBF);
                s->outport = (uint8_t)((s->outport | OUT_OBF) & ~OUT_MOUSE_OBF);
                break;
            case CMD_WRITE_MODE:
            case CMD_WRITE_OUTPORT:
            case CMD_WRITE_OBUF:
            case CMD_WRITE_AUX_OBUF:
            case CMD_WRITE_MOUSE:
                s->write_cmd = ncmd;  // arm: next 0x60 data byte consumed per cmd
                break;
            case CMD_MOUSE_DISABLE:
                s->mode = (uint8_t)(s->mode | MODE_DISABLE_MOUSE);
                break;
            case CMD_MOUSE_ENABLE:
                s->mode = (uint8_t)(s->mode & ~MODE_DISABLE_MOUSE);
                break;
            case CMD_TEST_MOUSE:
                s->cbdata  = 0x00u;
                s->status  = (uint8_t)((s->status | STAT_CMD | STAT_OBF) & ~STAT_MOUSE_OBF);
                s->outport = (uint8_t)((s->outport | OUT_OBF) & ~OUT_MOUSE_OBF);
                break;
            case CMD_SELF_TEST:
                s->cbdata  = 0x55u;
                s->status  = (uint8_t)((s->status | STAT_CMD | STAT_SELFTEST | STAT_OBF) & ~STAT_MOUSE_OBF);
                s->outport = (uint8_t)((s->outport | OUT_OBF) & ~OUT_MOUSE_OBF);
                break;
            case CMD_KBD_TEST:
                s->cbdata  = 0x00u;
                s->status  = (uint8_t)((s->status | STAT_CMD | STAT_OBF) & ~STAT_MOUSE_OBF);
                s->outport = (uint8_t)((s->outport | OUT_OBF) & ~OUT_MOUSE_OBF);
                break;
            case CMD_KBD_DISABLE:
                s->mode = (uint8_t)(s->mode | MODE_DISABLE_KBD);
                break;
            case CMD_KBD_ENABLE:
                s->mode = (uint8_t)(s->mode & ~MODE_DISABLE_KBD);
                break;
            case CMD_READ_INPORT:
                s->cbdata  = 0x80u;
                s->status  = (uint8_t)((s->status | STAT_CMD | STAT_OBF) & ~STAT_MOUSE_OBF);
                s->outport = (uint8_t)((s->outport | OUT_OBF) & ~OUT_MOUSE_OBF);
                break;
            case CMD_READ_OUTPORT:
                s->cbdata  = s->outport;
                s->status  = (uint8_t)((s->status | STAT_CMD | STAT_OBF) & ~STAT_MOUSE_OBF);
                s->outport = (uint8_t)((s->outport | OUT_OBF) & ~OUT_MOUSE_OBF);
                break;
            case CMD_ENABLE_A20:
                s->outport = (uint8_t)(s->outport | OUT_A20);
                break;
            case CMD_DISABLE_A20:
                s->outport = (uint8_t)(s->outport & ~OUT_A20);
                break;
            case CMD_RESET:
                // qemu_system_reset_request: reset_req pulse (out of model scope;
                // no register-surface side effect to mirror here).
                break;
            case CMD_NO_OP:
            default:
                // CMD_NO_OP / unsupported cmd: no state change (status|=CMD only).
                break;
        }
    } else {
        // WRITE to 0x60 (data). Base: status bit3 (CMD) cleared (last write was
        // data); the armed write_cmd is consumed. Routed per the OLD write_cmd
        // (kbd_write_data) — capture it before clearing, matching the RTL where
        // the case keys on the pre-update write_cmd register.
        uint8_t prev_cmd = s->write_cmd;
        s->status    = (uint8_t)(s->status & ~STAT_CMD);
        s->write_cmd = 0x00u;  // consume the armed command (QEMU: s->write_cmd=0)
        switch (prev_cmd) {
            case CMD_WRITE_MODE:
                s->mode = val;
                break;
            case CMD_WRITE_OBUF:
                // kbd_queue(val, 0): controller-sourced OBF
                s->cbdata  = val;
                s->status  = (uint8_t)(((s->status & ~STAT_CMD) | STAT_OBF) & ~STAT_MOUSE_OBF);
                s->outport = (uint8_t)((s->outport | OUT_OBF) & ~OUT_MOUSE_OBF);
                break;
            case CMD_WRITE_AUX_OBUF:
                // kbd_queue(val, 1): mouse-sourced controller OBF
                s->cbdata  = val;
                s->status  = (uint8_t)((s->status & ~STAT_CMD) | STAT_OBF | STAT_MOUSE_OBF);
                s->outport = (uint8_t)(s->outport | OUT_OBF | OUT_MOUSE_OBF);
                break;
            case CMD_WRITE_OUTPORT:
                // outport_write(val): set outport, A20 from bit1, reset if bit0=0.
                s->outport = val;
                // bit0=0 => reset_req pulse (out of model scope).
                break;
            case CMD_WRITE_MOUSE:
                // ps2_write_mouse + reenable: model only the re-enable side effect.
                s->mode = (uint8_t)(s->mode & ~MODE_DISABLE_MOUSE);
                break;
            default:
                // write_cmd == 0: byte sent to the keyboard. Re-enables kbd iface.
                s->mode = (uint8_t)(s->mode & ~MODE_DISABLE_KBD);
                break;
        }
    }
}

ven_periph_t* ven_i8042_new(void) {
    ven_periph_t* p = (ven_periph_t*)calloc(1, sizeof(ven_periph_t));
    p->state    = calloc(1, sizeof(i8042_state_t));
    p->reset    = i8042_reset;
    p->io_read  = i8042_read;
    p->io_write = i8042_write;
    p->irq      = i8042_irq;
    i8042_reset(p);
    return p;
}
