// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "ide_checkpoint.h"
#include <cassert>
#include <cstdio>

// Standalone tests use the actual device types without linking a simulator.
fileTYPE::fileTYPE() { std::memset(this, 0, sizeof(*this)); }
fileTYPE::~fileTYPE() {}

int main() {
    ide_config device[2]{};
    uint8_t buffer[32 * 512]{};
    fileTYPE disk;
    disk.filp = std::tmpfile(); assert(disk.filp);
    disk.size = 4096; disk.mode = 2;
    auto &d = device[0].drive[0];
    d.f = &disk; d.present = 1; d.cylinders = 37; d.heads = 4;
    d.spt = 17; d.spb = 8; d.total_sectors = 2516;
    d.id[47] = 8; d.id[255] = 0xa501;
    device[0].regs.status = ATA_STATUS_RDY | ATA_STATUS_DRQ;
    device[0].regs.sector_count = 3;
    buffer[0] = 0x12; buffer[16383] = 0x34;
    assert(fseeko(disk.filp, 777, SEEK_SET) == 0);
    disk.offset = 0; // Deliberately stale, just like the real file shim.
    ven_checkpoint::AtaState saved;
    assert(ven_checkpoint::capture_ata(device, buffer, saved));
    assert(saved.controller[0].drive[0].file_position == 777);
    d.spb = 16; d.cylinders = 99; d.id[47] = 16;
    device[0].regs.status = 0; buffer[0] = buffer[16383] = 0;
    assert(fseeko(disk.filp, 5, SEEK_SET) == 0);
    assert(ven_checkpoint::restore_ata(device, buffer, saved));
    assert(d.f == &disk && d.spb == 8 && d.cylinders == 37 && d.id[47] == 8);
    assert(d.id[255] == 0xa501 && ftello(disk.filp) == 777);
    assert(device[0].regs.status & ATA_STATUS_DRQ);
    assert(device[0].regs.sector_count == 3 && buffer[0] == 0x12 && buffer[16383] == 0x34);
    saved.version = 99;
    assert(!ven_checkpoint::restore_ata(device, buffer, saved));
    saved.version = 1; disk.size++;
    assert(!ven_checkpoint::restore_ata(device, buffer, saved));
    disk.size--; d.cd = 1;
    assert(!ven_checkpoint::capture_ata(device, buffer, saved));
    d.cd = 0; device[1].state = IDE_STATE_WAIT_PKT_CMD;
    assert(!ven_checkpoint::capture_ata(device, buffer, saved));
    device[1].state = IDE_STATE_IDLE;
    // Reject a mismatch on the LAST drive before touching the first one.
    saved.controller[1].drive[1].present = 1;
    d.spb = 23;
    assert(!ven_checkpoint::restore_ata(device, buffer, saved));
    assert(d.spb == 23 && ftello(disk.filp) == 777);
    std::fclose(disk.filp);
    std::puts("IDE-CHECKPOINT-UNIT-OK");
}
