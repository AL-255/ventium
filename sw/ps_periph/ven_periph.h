// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps_periph/ven_periph.h — the portable C peripheral-model interface.
//
// A PS-placed SoC peripheral (see fpga/periph_split.config) is a C model that
// services the I/O port range the PL forwards over the AXI-Lite io-bridge. The
// SAME .c file compiles into (a) tb_soc.cpp for per-record verification vs qemu
// (build ventium_soc with +VEN_<DEV>_PS, run the psoc<dev> gate -> EQUIVALENT),
// and (b) the A53 firmware for the board. Each model mirrors its ven_*.sv RTL
// register logic exactly, so "C model == RTL == qemu".

#ifndef VEN_PERIPH_H
#define VEN_PERIPH_H
#include <stdint.h>

typedef struct ven_periph {
    void*    state;
    void   (*reset)   (struct ven_periph*);
    uint8_t (*io_read) (struct ven_periph*, uint16_t port);
    void   (*io_write)(struct ven_periph*, uint16_t port, uint8_t val);
    int    (*irq)     (struct ven_periph*);  // IRQ level (0/1), or -1 if no IRQ line
    // Optional 16-bit accessors (default NULL). Only the IDE/ATA data port (0x1F0)
    // is word-wide; ven_soc_app calls these when the io-bridge reports io_size==2.
    uint16_t (*io_read16) (struct ven_periph*, uint16_t port);
    void     (*io_write16)(struct ven_periph*, uint16_t port, uint16_t val);
} ven_periph_t;

// A model's constructor allocates + resets its state and returns the vtable.
typedef ven_periph_t* (*ps_periph_ctor_t)(void);

// One row of the generated dispatch table (verif/tb/ps_periph_table.inc).
typedef struct {
    const char*      dev;
    ps_periph_ctor_t ctor;
    uint16_t         lo, hi;   // inclusive I/O port range serviced by this model
} ps_periph_entry_t;

#endif // VEN_PERIPH_H
