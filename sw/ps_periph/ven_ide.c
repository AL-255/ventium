#define _GNU_SOURCE 1
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps_periph/ven_ide.c — IDE/ATA primary-master C model (PS-placed peripheral).
//
// Read-path port of rtl/soc/ven_ide.sv's CPU-observable behavior, backed by a host
// disk image FILE (so a multi-MiB FreeDOS disk works without the RTL's fixed disk[]).
// Serves the command block 0x1F0-0x1F7 + control 0x3F6. Implements what SeaBIOS INT13
// + FreeDOS need to BOOT (read-only): IDENTIFY (0xEC), READ SECTORS (0x20/0x21), the
// BSY->DRQ status handshake (0x58 in a read-DRQ window, 0x50 idle/commit), CHS + LBA28
// addressing, the 16-bit data-port (0x1F0) word drain, and IRQ14 (nIEN-gated). WRITE
// (0x30) is intentionally NOT served — the boot path is read-only and the core's OUTS
// string-write halts anyway; a write command aborts (0x41/0x04).
//
// IDENTIFY words are the qemu-8.2.2 values ported verbatim from ven_ide.sv with the
// geometry computed from the image size (guess_chs_for_size: 16 heads, 63 secs).

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include "ven_periph.h"

typedef struct {
    int      fd;
    uint64_t total_sectors;
    uint32_t cyls, heads, secs;
    uint16_t ident[256];
    // task-file registers
    uint8_t  features, error, nsector, sector, lcyl, hcyl, select, status, command, ctrl;
    // transfer state
    int      drq, in_identify, irq;
    uint32_t xfer_lba;          // LBA28
    int      nsec_left;
    int      data_idx;          // word 0..255 within the 512-byte buffer
    uint8_t  sbuf[512];         // current sector buffer
} ide_t;

#define ST_BSY  0x80
#define ST_DRDY 0x40
#define ST_DRQ  0x08
#define ST_ERR  0x01
#define ST_IDLE 0x50   // DRDY | SEEK/DSC
#define ST_DRQW 0x58   // DRDY | DSC | DRQ  (a read-DRQ window)
#define ST_ABRT 0x41   // DRDY | ERR
#define ERR_ABRT 0x04

static void build_identify(ide_t* s) {
    memset(s->ident, 0, sizeof(s->ident));
    uint32_t C = s->cyls, H = s->heads, S = s->secs;
    uint32_t oldsize = C * H * S;
    s->ident[0]  = 0x0040;
    s->ident[1]  = (uint16_t)C; s->ident[3] = (uint16_t)H;
    s->ident[4]  = (uint16_t)(512 * S); s->ident[5] = 512; s->ident[6] = (uint16_t)S;
    s->ident[54] = (uint16_t)C; s->ident[55] = (uint16_t)H; s->ident[56] = (uint16_t)S;
    s->ident[57] = (uint16_t)(oldsize & 0xffff); s->ident[58] = (uint16_t)(oldsize >> 16);
    s->ident[60] = (uint16_t)(s->total_sectors & 0xffff);
    s->ident[61] = (uint16_t)((s->total_sectors >> 16) & 0xffff);
    s->ident[100]= (uint16_t)(s->total_sectors & 0xffff);
    // serial "QM00001", firmware "2.5+", model "QEMU HARDDISK" (byte-swapped, padded)
    s->ident[10]=0x514d; s->ident[11]=0x3030; s->ident[12]=0x3030; s->ident[13]=0x3120;
    s->ident[14]=0x2020; s->ident[15]=0x2020; s->ident[16]=0x2020; s->ident[17]=0x2020;
    s->ident[18]=0x2020; s->ident[19]=0x2020;
    s->ident[23]=0x322e; s->ident[24]=0x352b; s->ident[25]=0x2020; s->ident[26]=0x2020;
    s->ident[27]=0x5145; s->ident[28]=0x4d55; s->ident[29]=0x2048; s->ident[30]=0x4152;
    s->ident[31]=0x4444; s->ident[32]=0x4953; s->ident[33]=0x4b20;
    for (int i=34;i<=46;i++) s->ident[i]=0x2020;
    s->ident[20]=0x0003; s->ident[21]=0x0200; s->ident[22]=0x0004; s->ident[47]=0x8010;
    s->ident[48]=0x0001; s->ident[49]=0x0b00; s->ident[51]=0x0200; s->ident[52]=0x0200;
    s->ident[53]=0x0007; s->ident[59]=0x0110; s->ident[62]=0x0007; s->ident[63]=0x0007;
    s->ident[64]=0x0003; s->ident[65]=0x0078; s->ident[66]=0x0078; s->ident[67]=0x0078;
    s->ident[68]=0x0078; s->ident[69]=0x4000; s->ident[80]=0x00f0; s->ident[81]=0x0016;
    s->ident[82]=0x4021; s->ident[83]=0x7400; s->ident[84]=0x4000; s->ident[85]=0x4021;
    s->ident[86]=0x3400; s->ident[87]=0x4000; s->ident[88]=0x203f; s->ident[93]=0x6001;
    s->ident[106]=0x6000; s->ident[169]=0x0001;
}

static int is_unit1(ide_t* s) { return (s->select >> 4) & 1; }   // bit4 = drive select

// resolve the current LBA from the task-file (LBA bit6, else CHS).
static uint32_t cur_lba(ide_t* s) {
    if (s->select & 0x40)   // LBA mode
        return ((uint32_t)(s->select & 0x0f) << 24) | ((uint32_t)s->hcyl << 16)
             | ((uint32_t)s->lcyl << 8) | s->sector;
    // CHS: (cyl*HEADS + head)*SECS + sector - 1
    uint32_t cyl = ((uint32_t)s->hcyl << 8) | s->lcyl;
    uint32_t head = s->select & 0x0f;
    return (cyl * s->heads + head) * s->secs + (s->sector ? s->sector - 1 : 0);
}

static void load_sector(ide_t* s) {
    memset(s->sbuf, 0, 512);
    if (s->fd >= 0 && s->xfer_lba < s->total_sectors)
        if (pread(s->fd, s->sbuf, 512, (off_t)s->xfer_lba * 512) < 0) { /* leave zeros */ }
}

static void start_read(ide_t* s) {
    if (is_unit1(s)) { s->status = 0; return; }   // absent slave
    uint32_t lba = cur_lba(s);
    int n = s->nsector ? s->nsector : 256;
    if (lba >= s->total_sectors) { s->status = ST_ABRT; s->error = ERR_ABRT; s->irq = 1; return; }
    s->xfer_lba = lba; s->nsec_left = n; s->data_idx = 0; s->in_identify = 0;
    load_sector(s);
    s->drq = 1; s->status = ST_DRQW; s->error = 0; s->irq = 1;   // ready to transfer
}

static void start_identify(ide_t* s) {
    if (is_unit1(s)) { s->status = 0; return; }
    s->in_identify = 1; s->data_idx = 0; s->nsec_left = 1;
    s->drq = 1; s->status = ST_DRQW; s->error = 0; s->irq = 1;
}

static void ide_reset(ven_periph_t* p) {
    ide_t* s = (ide_t*)p->state;
    s->features=s->error=s->nsector=s->sector=s->lcyl=s->hcyl=0;
    s->select = 0xA0; s->status = ST_IDLE; s->command = 0; s->ctrl = 0;
    s->drq = s->in_identify = s->irq = 0; s->data_idx = 0; s->nsec_left = 0;
    s->nsector = 1; s->sector = 1;   // ATA reset signature (sector count/number = 1)
}

static uint8_t ide_read8(ven_periph_t* p, uint16_t port) {
    ide_t* s = (ide_t*)p->state;
    switch (port) {
        case 0x1F1: return is_unit1(s) ? 0 : s->error;
        case 0x1F2: return is_unit1(s) ? 0 : s->nsector;
        case 0x1F3: return is_unit1(s) ? 0 : s->sector;
        case 0x1F4: return is_unit1(s) ? 0 : s->lcyl;
        case 0x1F5: return is_unit1(s) ? 0 : s->hcyl;
        case 0x1F6: return s->select;
        case 0x1F7: s->irq = 0; return is_unit1(s) ? 0 : s->status;  // status read clears INTRQ
        case 0x3F6: return is_unit1(s) ? 0 : s->status;              // alt status (no INTRQ clear)
        case 0x1F0: return 0;   // byte read of the data port is unusual; word path below
        default:    return 0xFF;
    }
}

static void ide_exec(ide_t* s, uint8_t cmd) {
    s->command = cmd;
    switch (cmd) {
        case 0xEC: start_identify(s); break;                 // IDENTIFY DEVICE
        case 0x20: case 0x21: start_read(s); break;          // READ SECTORS (w/ + w/o retry)
        case 0x90: s->status = ST_IDLE; s->error = 0x01; s->irq = 1; break;  // EXECUTE DIAGNOSTIC
        case 0x91: s->status = ST_IDLE; s->irq = 1; break;   // INITIALIZE DEVICE PARAMETERS (accept)
        case 0xC6: s->status = ST_IDLE; s->irq = 1; break;   // SET MULTIPLE (status-only)
        case 0xEF: s->status = ST_IDLE; s->irq = 1; break;   // SET FEATURES (accept)
        default:   s->status = ST_ABRT; s->error = ERR_ABRT; s->irq = 1; break;  // incl WRITE
    }
}

static void ide_write8(ven_periph_t* p, uint16_t port, uint8_t val) {
    ide_t* s = (ide_t*)p->state;
    // task-file register writes are dropped mid-DRQ (qemu core.c:1287), except 0x1F6/cmd/ctrl.
    switch (port) {
        case 0x1F1: if (!s->drq) s->features = val; break;
        case 0x1F2: if (!s->drq) s->nsector  = val; break;
        case 0x1F3: if (!s->drq) s->sector   = val; break;
        case 0x1F4: if (!s->drq) s->lcyl     = val; break;
        case 0x1F5: if (!s->drq) s->hcyl     = val; break;
        case 0x1F6: s->select = val; break;
        case 0x1F7: if (!s->drq) ide_exec(s, val); break;    // command (ignored while DRQ)
        case 0x3F6:
            if ((val & 0x04) && !(s->ctrl & 0x04)) ide_reset(p);  // SRST edge
            s->ctrl = val;
            break;
        default: break;
    }
}

// 16-bit data port (0x1F0) read — the PIO drain. Advances the word pointer; on the
// last word of a sector, advances/commits (re-arms the next sector or ends the cmd).
static uint16_t ide_read16(ven_periph_t* p, uint16_t port) {
    ide_t* s = (ide_t*)p->state;
    if (port != 0x1F0 || !s->drq) return 0;
    uint16_t w;
    if (s->in_identify) w = s->ident[s->data_idx];
    else                w = (uint16_t)(s->sbuf[s->data_idx*2] | (s->sbuf[s->data_idx*2+1] << 8));
    s->data_idx++;
    if (s->data_idx >= 256) {                 // end of this 512-byte buffer
        if (!s->in_identify && s->nsec_left > 1) {
            s->nsec_left--; s->xfer_lba++; s->data_idx = 0;
            load_sector(s);
            s->status = ST_DRQW; s->irq = 1;   // next sector ready (re-arm INTRQ)
        } else {                               // transfer complete -> commit
            s->drq = 0; s->in_identify = 0; s->status = ST_IDLE;
            // advance the LBA/sector registers to the last-transferred sector (LBA mode)
            if (s->select & 0x40) {
                uint32_t last = s->xfer_lba;
                s->sector = last & 0xff; s->lcyl = (last >> 8) & 0xff;
                s->hcyl = (last >> 16) & 0xff;
                s->select = (uint8_t)((s->select & 0xf0) | ((last >> 24) & 0x0f));
            }
            s->nsector = 0;
        }
    }
    return w;
}

static int ide_irq(ven_periph_t* p) {
    ide_t* s = (ide_t*)p->state;
    if (s->ctrl & 0x02) return 0;    // nIEN: IRQ disabled (polled mode)
    return s->irq;
}

ven_periph_t* ven_ide_new(const char* path) {
    ven_periph_t* p = (ven_periph_t*)calloc(1, sizeof(*p));
    ide_t* s = (ide_t*)calloc(1, sizeof(ide_t));
    p->state = s;
    s->fd = path ? open(path, O_RDONLY) : -1;
    off_t sz = 0;
    if (s->fd >= 0) { sz = lseek(s->fd, 0, SEEK_END); lseek(s->fd, 0, SEEK_SET); }
    s->total_sectors = sz > 0 ? (uint64_t)sz / 512 : 0;
    // guess_chs_for_size: 16 heads, 63 secs, cyls = total/(16*63)
    s->heads = 16; s->secs = 63;
    s->cyls  = s->total_sectors ? (uint32_t)(s->total_sectors / (16 * 63)) : 0;
    if (s->cyls == 0) s->cyls = 1;
    if (s->cyls > 65535) s->cyls = 65535;
    build_identify(s);
    p->reset = ide_reset; p->io_read = ide_read8; p->io_write = ide_write8;
    p->irq = ide_irq; p->io_read16 = ide_read16; p->io_write16 = 0;
    ide_reset(p);
    fprintf(stderr, "ven_ide: %s  %llu sectors  CHS=%u/%u/%u\n",
            path ? path : "(none)", (unsigned long long)s->total_sectors, s->cyls, s->heads, s->secs);
    return p;
}
