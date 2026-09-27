// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "file_io.h"
#include "ide.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <type_traits>

// Native, same-build checkpoint payload. No FILE*, paths, CHD pointers or
// owning C++ objects may enter the serialized representation. Disk contents
// and identity are the enclosing checkpoint bundle's responsibility.
namespace ven_checkpoint {
struct AtaDrive {
    uint8_t present, drvnum, cd, placeholder, allow_placeholder;
    uint16_t cylinders, heads, spt;
    uint32_t total_sectors, spb, offset, type;
    uint16_t id[256];
    uint8_t file_open;
    int32_t file_mode;
    int64_t file_size, file_position;
};
struct AtaController {
    uint32_t base, bitoff, state, null_data, prepcnt;
    regs_t regs;
    AtaDrive drive[2];
};
struct AtaState {
    uint32_t version = 1;
    AtaController controller[2]{};
    uint8_t buffer[32 * 512]{};
};
static_assert(std::is_trivially_copyable<AtaState>::value);

inline bool ata_supported(const ide_config (&controllers)[2]) {
    for (const auto &c : controllers) {
        // ATAPI packet phases require additional state not covered here.
        if (c.state > IDE_STATE_INIT_RW) return false;
        for (const auto &d : c.drive) {
            if ((d.present && d.cd) || d.chd_f || d.chd_hunkbuf || d.track_cnt ||
                d.playing || d.paused) return false;
            if (d.f && (d.f->zip || d.f->type)) return false;
            if (d.present && (!d.f || !d.f->filp)) return false;
        }
    }
    return true;
}

// Call only outside host polling/transfer functions. Idle+DRQ is permitted:
// the matching RTL checkpoint retains the guest's partially drained buffer.
inline bool capture_ata(const ide_config (&controllers)[2], const uint8_t *buffer,
                        AtaState &out) {
    if (!ata_supported(controllers)) return false;
    AtaState next{};
    for (unsigned p = 0; p < 2; ++p) {
        const auto &c = controllers[p]; auto &s = next.controller[p];
        s.base = c.base; s.bitoff = c.bitoff; s.state = c.state;
        s.null_data = c.null; s.prepcnt = c.prepcnt; s.regs = c.regs;
        for (unsigned i = 0; i < 2; ++i) {
            const auto &d = c.drive[i]; auto &v = s.drive[i];
            v.present = d.present; v.drvnum = d.drvnum; v.cd = d.cd;
            v.placeholder = d.placeholder; v.allow_placeholder = d.allow_placeholder;
            v.cylinders = d.cylinders; v.heads = d.heads; v.spt = d.spt;
            v.total_sectors = d.total_sectors; v.spb = d.spb;
            v.offset = d.offset; v.type = d.type;
            std::memcpy(v.id, d.id, sizeof(v.id));
            v.file_open = d.f && d.f->filp;
            if (v.file_open) {
                // Flush writes before the enclosing bundle copies the disk.
                if (std::fflush(d.f->filp)) return false;
                v.file_position = ftello(d.f->filp);
                if (v.file_position < 0) return false;
                v.file_size = d.f->size; v.file_mode = d.f->mode;
            }
        }
    }
    std::memcpy(next.buffer, buffer, sizeof(next.buffer));
    out = next;
    return true;
}

// Mount validated private disk copies first. A failure is fatal to a restore:
// do not resume execution after a failed seek. No pointer is replaced or freed.
inline bool restore_ata(ide_config (&controllers)[2], uint8_t *buffer,
                        const AtaState &saved) {
    if (saved.version != 1 || !ata_supported(controllers)) return false;
    // Check every drive before modifying controller metadata or file positions.
    for (unsigned p = 0; p < 2; ++p) {
        const auto &c = controllers[p]; const auto &s = saved.controller[p];
        if (s.state > IDE_STATE_INIT_RW || s.regs.drv > 1 ||
            c.base != s.base || c.bitoff != s.bitoff) return false;
        for (unsigned i = 0; i < 2; ++i) {
            const auto &d = c.drive[i]; const auto &v = s.drive[i];
            if (d.present != v.present || d.drvnum != v.drvnum || d.cd != v.cd ||
                d.placeholder != v.placeholder || d.allow_placeholder != v.allow_placeholder ||
                v.file_open != bool(d.f && d.f->filp)) return false;
            if (v.file_open && (d.f->size != v.file_size || d.f->mode != v.file_mode ||
                                v.file_position < 0)) return false;
        }
    }
    for (unsigned p = 0; p < 2; ++p) {
        auto &c = controllers[p]; const auto &s = saved.controller[p];
        for (unsigned i = 0; i < 2; ++i) {
            auto &d = c.drive[i]; const auto &v = s.drive[i];
            if (v.file_open && fseeko(d.f->filp, v.file_position, SEEK_SET)) return false;
            d.cylinders = v.cylinders; d.heads = v.heads; d.spt = v.spt;
            d.total_sectors = v.total_sectors; d.spb = v.spb;
            d.offset = v.offset; d.type = v.type;
            std::memcpy(d.id, v.id, sizeof(d.id));
        }
        c.state = s.state; c.null = s.null_data; c.prepcnt = s.prepcnt;
        c.regs = s.regs;
    }
    std::memcpy(buffer, saved.buffer, sizeof(saved.buffer));
    return true;
}
} // namespace ven_checkpoint
