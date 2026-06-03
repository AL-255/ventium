// verif/tb/memmodel.cpp
//
// Implementation of the flat memory + mem_* bus-functional model.
// See memmodel.h and docs/rtl-interface.md §3/§4.
#include "memmodel.h"

#include <cstdio>

namespace ventium {

MemModel::Page& MemModel::page_for(uint32_t addr) {
    return pages_[addr >> PAGE_SHIFT];   // default-constructs (zeroed) if absent
}

const MemModel::Page* MemModel::page_lookup(uint32_t addr) const {
    auto it = pages_.find(addr >> PAGE_SHIFT);
    return (it == pages_.end()) ? nullptr : &it->second;
}

uint8_t MemModel::read8(uint32_t addr) const {
    const Page* p = page_lookup(addr);
    return p ? p->b[addr & PAGE_MASK] : 0u;   // unmapped reads as 0 (M0)
}

void MemModel::write8(uint32_t addr, uint8_t val) {
    page_for(addr).b[addr & PAGE_MASK] = val;
}

uint32_t MemModel::read32(uint32_t addr) const {
    // Little-endian; byte-wise to be safe across page boundaries.
    return  (uint32_t)read8(addr)
         | ((uint32_t)read8(addr + 1) << 8)
         | ((uint32_t)read8(addr + 2) << 16)
         | ((uint32_t)read8(addr + 3) << 24);
}

void MemModel::write32(uint32_t addr, uint32_t val) {
    write8(addr,     (uint8_t)(val & 0xff));
    write8(addr + 1, (uint8_t)((val >> 8) & 0xff));
    write8(addr + 2, (uint8_t)((val >> 16) & 0xff));
    write8(addr + 3, (uint8_t)((val >> 24) & 0xff));
}

long MemModel::load_image(const std::string& path, uint32_t load_addr) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return -1;
    long n = 0;
    int c;
    uint32_t a = load_addr;
    while ((c = std::fgetc(f)) != EOF) {
        write8(a++, (uint8_t)c);
        ++n;
    }
    std::fclose(f);
    return n;
}

void MemModel::service(bool req, bool we, uint32_t addr, uint32_t wdata,
                       uint8_t wstrb, uint32_t* rdata, bool* ack) {
    if (!req) {
        *rdata = 0;
        *ack   = false;
        return;
    }

    if (we) {
        // Honour per-byte write strobes (mem_wstrb). docs/rtl-interface.md §3.
        for (int i = 0; i < 4; ++i) {
            if (wstrb & (1u << i)) {
                write8(addr + (uint32_t)i, (uint8_t)((wdata >> (8 * i)) & 0xff));
            }
        }
        ++writes_;
        *rdata = 0;             // read data undefined on writes; drive 0
    } else {
        *rdata = read32(addr);
        ++reads_;
    }
    *ack = true;               // single-beat: ack immediately (M0, §3)
}

}  // namespace ventium
