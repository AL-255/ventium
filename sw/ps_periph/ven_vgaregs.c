// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps_periph/ven_vgaregs.c — PS C model of the VGA register-file device.
//
// A 1:1 behavioural port of rtl/soc/ven_vgaregs.sv (qemu-grounded vs QEMU 8.2.2
// hw/display/vga.c). Services 0x3B0-0x3DF (the standard VGA register window) when
// the device is PS-placed; verified bit-exact vs qemu-system by the soc-ps cosim
// gate built with +VEN_VGA_PS (the C model serves the port range instead of the
// RTL module). SCOPE: the CPU-observable VGA *register set* + its side effects
// ONLY — NOT the framebuffer / scan-out path.
//
// The RTL's clocked read side-effects (DAC palette auto-increment, IS1 retrace
// toggle + attr flip-flop reset) become inline read side-effects here — the
// bridge calls io_read exactly once per IN, so the effect is identical.

#include "ven_periph.h"
#include <stdlib.h>

// ---- QEMU register port addresses (vga_regs.h) ----------------------------
#define VGA_ATT_W   0x3C0  // attr index/data write
#define VGA_ATT_R   0x3C1  // attr data read
#define VGA_MIS_W   0x3C2  // misc output write / st00 read
#define VGA_SEQ_I   0x3C4  // sequencer index
#define VGA_SEQ_D   0x3C5  // sequencer data
#define VGA_PEL_IR  0x3C7  // DAC read index (W) / dac_state (R)
#define VGA_PEL_IW  0x3C8  // DAC write index
#define VGA_PEL_D   0x3C9  // DAC palette data
#define VGA_FTC_R   0x3CA  // feature control read (fcr)
#define VGA_MIS_R   0x3CC  // misc output read (msr)
#define VGA_GFX_I   0x3CE  // graphics index
#define VGA_GFX_D   0x3CF  // graphics data
#define VGA_CRT_IC  0x3D4  // CRTC index (color)
#define VGA_CRT_IM  0x3B4  // CRTC index (mono)
#define VGA_CRT_DC  0x3D5  // CRTC data (color)
#define VGA_CRT_DM  0x3B5  // CRTC data (mono)
#define VGA_IS1_RC  0x3DA  // input status 1 (color)
#define VGA_IS1_RM  0x3BA  // input status 1 (mono)

// ---- QEMU constants -------------------------------------------------------
#define VGA_ATT_C            0x15  // #attr regs
#define VGA_CR11_LOCK        0x80  // CR11 bit7 locks CR0-7
#define VGA_CRTC_OVERFLOW    0x07  // CR7  (cr[] index)
#define VGA_CRTC_V_SYNC_END  0x11  // CR11 (cr[] index)
#define ST01_TOGGLE          0x09  // V_RETRACE|DISP_ENABLE

// ---- Architectural state (matches VGACommonState fields) ------------------
typedef struct {
    uint8_t  ar_index;        // attribute index (6 bits; QEMU masks val & 0x3f)
    uint8_t  ar_flip_flop;    // 0 = index phase, 1 = data phase
    uint8_t  ar[21];          // attribute regs ar[0..0x14]

    uint8_t  msr;             // misc output register
    uint8_t  fcr;             // feature control register
    uint8_t  st00;            // input status 0 (read-only here, stays reset)
    uint8_t  st01;            // input status 1 (toggles on IS1 read)

    uint8_t  sr_index;        // sequencer index (val & 7)
    uint8_t  sr[8];           // sequencer regs

    uint8_t  gr_index;        // graphics index (val & 0x0f)
    uint8_t  gr[16];          // graphics regs

    uint8_t  cr_index;        // CRTC index (full 8 bits)
    uint8_t  cr[256];         // CRTC regs

    uint8_t  dac_state;       // PEL state: 0 after write-index, 3 after read-index
    uint8_t  dac_sub_index;   // 0/1/2 -> R/G/B sub-byte
    uint8_t  dac_read_index;  // PEL read index
    uint8_t  dac_write_index; // PEL write index
    uint8_t  dac_cache[3];    // 3-byte write staging cache
    uint8_t  palette[768];    // 256 * 3 = 768-byte palette
} vga_state_t;

// ---- Per-index write masks (sr_mask / gr_mask from vga.c) ------------------
static uint8_t vga_sr_mask(uint8_t idx) {
    switch (idx & 7) {
        case 0: return 0x03;
        case 1: return 0x3d;
        case 2: return 0x0f;
        case 3: return 0x3f;
        case 4: return 0x0e;
        case 5: return 0x00;
        case 6: return 0x00;
        case 7: return 0xff;
        default: return 0x00;
    }
}

static uint8_t vga_gr_mask(uint8_t idx) {
    switch (idx & 0x0f) {
        case 0x0: return 0x0f;
        case 0x1: return 0x0f;
        case 0x2: return 0x0f;
        case 0x3: return 0x1f;
        case 0x4: return 0x03;
        case 0x5: return 0x7b;
        case 0x6: return 0x0f;
        case 0x7: return 0x0f;
        case 0x8: return 0xff;
        default:  return 0x00;  // 0x09..0x0f
    }
}

// ---- Attribute-register per-index write mask (vga.c lines 457-478) ----------
// Returns the masked value to store; idx is ar_index & 0x1f.
static uint8_t vga_ar_write_val(uint8_t idx, uint8_t val) {
    if (idx <= 0x0F)       return (uint8_t)(val & 0x3f);   // PALETTE0..F
    else if (idx == 0x10)  return (uint8_t)(val & ~0x10);  // ATC_MODE
    else if (idx == 0x11)  return val;                     // ATC_OVERSCAN
    else if (idx == 0x12)  return (uint8_t)(val & ~0xc0);  // PLANE_ENABLE
    else if (idx == 0x13)  return (uint8_t)(val & ~0xf0);  // ATC_PEL
    else if (idx == 0x14)  return (uint8_t)(val & ~0xf0);  // COLOR_PAGE
    else                   return val;                     // default (>0x14)
}

// ---- Color/mono port validity (vga_ioport_invalid, vga.c line 338) ----------
// msr bit0 set => COLOR mode => 0x3b0..0x3bf invalid.
//              clear => MONO  mode => 0x3d0..0x3df invalid.
static int vga_port_invalid(const vga_state_t* s, uint16_t a) {
    if (s->msr & 0x01)  // VGA_MIS_COLOR
        return (a >= 0x3b0) && (a <= 0x3bf);
    else
        return (a >= 0x3d0) && (a <= 0x3df);
}

static void vga_reset(ven_periph_t* p) {
    vga_state_t* s = (vga_state_t*)p->state;
    int i;
    s->ar_index = 0; s->ar_flip_flop = 0;
    for (i = 0; i <= 20; i++) s->ar[i] = 0x00;
    s->msr = 0x00; s->fcr = 0x00; s->st00 = 0x00; s->st01 = 0x00;
    s->sr_index = 0;
    for (i = 0; i <= 7;  i++) s->sr[i] = 0x00;
    s->gr_index = 0;
    for (i = 0; i <= 15; i++) s->gr[i] = 0x00;
    s->cr_index = 0x00;
    for (i = 0; i <= 255; i++) s->cr[i] = 0x00;
    s->dac_state = 0x00; s->dac_sub_index = 0;
    s->dac_read_index = 0x00; s->dac_write_index = 0x00;
    s->dac_cache[0] = 0x00; s->dac_cache[1] = 0x00; s->dac_cache[2] = 0x00;
    for (i = 0; i <= 767; i++) s->palette[i] = 0x00;
}

// io_read returns the CPU-visible byte INCLUDING the RTL's clocked read
// side-effects (DAC auto-increment, IS1 retrace toggle + attr ff reset).
static uint8_t vga_read(ven_periph_t* p, uint16_t port) {
    vga_state_t* s = (vga_state_t*)p->state;

    // Invalid (color/mono aliased) ports read 0xff with NO side effect.
    if (vga_port_invalid(s, port))
        return 0xff;

    uint8_t v = 0x00;
    uint8_t ar_idx5 = (uint8_t)(s->ar_index & 0x1f);

    switch (port) {
        case VGA_ATT_W:
            v = (s->ar_flip_flop == 0) ? (uint8_t)(s->ar_index & 0x3f) : 0x00;
            break;
        case VGA_ATT_R:
            v = (ar_idx5 < VGA_ATT_C) ? s->ar[ar_idx5] : 0x00;
            break;
        case VGA_MIS_W:                 // read 0x3c2 -> st00
            v = s->st00;
            break;
        case VGA_SEQ_I:
            v = (uint8_t)(s->sr_index & 7);
            break;
        case VGA_SEQ_D:
            v = s->sr[s->sr_index & 7];
            break;
        case VGA_PEL_IR:                // read 0x3c7 -> dac_state
            v = s->dac_state;
            break;
        case VGA_PEL_IW:                // read 0x3c8 -> write index
            v = s->dac_write_index;
            break;
        case VGA_PEL_D: {               // read palette[read*3 + sub], then auto-inc
            int pal_addr = (int)s->dac_read_index * 3 + (int)s->dac_sub_index;
            v = s->palette[pal_addr];
            // DAC palette read auto-increment: ++sub; wrap at 3 -> read++
            if (s->dac_sub_index == 2) {
                s->dac_sub_index  = 0;
                s->dac_read_index = (uint8_t)(s->dac_read_index + 1);
            } else {
                s->dac_sub_index = (uint8_t)(s->dac_sub_index + 1);
            }
            break;
        }
        case VGA_FTC_R:
            v = s->fcr;
            break;
        case VGA_MIS_R:
            v = s->msr;
            break;
        case VGA_GFX_I:
            v = (uint8_t)(s->gr_index & 0x0f);
            break;
        case VGA_GFX_D:
            v = s->gr[s->gr_index & 0x0f];
            break;
        case VGA_CRT_IC:
        case VGA_CRT_IM:
            v = s->cr_index;
            break;
        case VGA_CRT_DC:
        case VGA_CRT_DM:
            v = s->cr[s->cr_index];
            break;
        case VGA_IS1_RC:
        case VGA_IS1_RM:
            // dumb retrace: returns st01 ^ 0x09; side effects toggle st01 + reset ff.
            v = (uint8_t)(s->st01 ^ ST01_TOGGLE);
            s->st01         = (uint8_t)(s->st01 ^ ST01_TOGGLE);
            s->ar_flip_flop = 0;
            break;
        default:
            v = 0x00;
            break;
    }
    return v;
}

static void vga_write(ven_periph_t* p, uint16_t port, uint8_t val) {
    vga_state_t* s = (vga_state_t*)p->state;

    // Invalid (color/mono aliased) ports ignore writes.
    if (vga_port_invalid(s, port))
        return;

    uint8_t ar_idx5 = (uint8_t)(s->ar_index & 0x1f);

    switch (port) {
        // ---- ATTRIBUTE (0x3c0): toggling index/data port -------------------
        case VGA_ATT_W:
            if (s->ar_flip_flop == 0) {
                s->ar_index = (uint8_t)(val & 0x3f);
            } else {
                if (ar_idx5 <= 0x14)
                    s->ar[ar_idx5] = vga_ar_write_val(ar_idx5, val);
            }
            s->ar_flip_flop = (uint8_t)(s->ar_flip_flop ^ 1);  // toggle each write
            break;

        // ---- MISC OUTPUT (0x3c2) -------------------------------------------
        case VGA_MIS_W:
            s->msr = (uint8_t)(val & ~0x10);
            break;

        // ---- SEQUENCER -----------------------------------------------------
        case VGA_SEQ_I:
            s->sr_index = (uint8_t)(val & 7);
            break;
        case VGA_SEQ_D:
            s->sr[s->sr_index & 7] = (uint8_t)(val & vga_sr_mask(s->sr_index));
            break;

        // ---- DAC -----------------------------------------------------------
        case VGA_PEL_IR:                // read index write
            s->dac_read_index = val;
            s->dac_sub_index  = 0;
            s->dac_state      = 3;
            break;
        case VGA_PEL_IW:                // write index write
            s->dac_write_index = val;
            s->dac_sub_index   = 0;
            s->dac_state       = 0;
            break;
        case VGA_PEL_D:                 // palette data write (3-byte cache)
            s->dac_cache[s->dac_sub_index] = val;
            if (s->dac_sub_index == 2) {
                // commit 3-byte cache: bytes 0,1 from cache, byte 2 is this val.
                int base = (int)s->dac_write_index * 3;
                s->palette[base + 0] = s->dac_cache[0];
                s->palette[base + 1] = s->dac_cache[1];
                s->palette[base + 2] = val;
                s->dac_sub_index   = 0;
                s->dac_write_index = (uint8_t)(s->dac_write_index + 1);
            } else {
                s->dac_sub_index = (uint8_t)(s->dac_sub_index + 1);
            }
            break;

        // ---- GRAPHICS ------------------------------------------------------
        case VGA_GFX_I:
            s->gr_index = (uint8_t)(val & 0x0f);
            break;
        case VGA_GFX_D:
            s->gr[s->gr_index & 0x0f] = (uint8_t)(val & vga_gr_mask(s->gr_index));
            break;

        // ---- CRTC ----------------------------------------------------------
        case VGA_CRT_IC:
        case VGA_CRT_IM:
            s->cr_index = val;          // full 8 bits
            break;
        case VGA_CRT_DC:
        case VGA_CRT_DM:
            // CR0-7 protection: if CR11 bit7 set and idx<=CR7, locked, except
            // CR7 bit4 is always writable.
            if ((s->cr[VGA_CRTC_V_SYNC_END] & VGA_CR11_LOCK) != 0x00 &&
                s->cr_index <= VGA_CRTC_OVERFLOW) {
                if (s->cr_index == VGA_CRTC_OVERFLOW) {
                    // CR7: only bit4 writable
                    s->cr[VGA_CRTC_OVERFLOW] =
                        (uint8_t)((s->cr[VGA_CRTC_OVERFLOW] & ~0x10) | (val & 0x10));
                }
                // else: write fully ignored (locked)
            } else {
                s->cr[s->cr_index] = val;
            }
            break;

        // ---- INPUT STATUS 1 write (3da/3ba) -> feature control -------------
        case VGA_IS1_RC:
        case VGA_IS1_RM:
            s->fcr = (uint8_t)(val & 0x10);
            break;

        default:
            break;
    }
}

ven_periph_t* ven_vgaregs_new(void) {
    ven_periph_t* p = (ven_periph_t*)calloc(1, sizeof(ven_periph_t));
    p->state    = calloc(1, sizeof(vga_state_t));
    p->reset    = vga_reset;
    p->io_read  = vga_read;
    p->io_write = vga_write;
    p->irq      = 0;            // no IRQ line (VGA register file)
    vga_reset(p);
    return p;
}
