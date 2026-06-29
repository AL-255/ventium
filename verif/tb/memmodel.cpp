// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/tb/memmodel.cpp
//
// Implementation of the flat memory + mem_* bus-functional model.
// See memmodel.h and docs/rtl-interface.md §3/§4.
#include "memmodel.h"

#include <cstdio>
#include <cstdlib>

namespace ventium {

// KV260 carveout fold: under VEN_KV260_SOC the L1AXI master remaps every guest
// access into the 256 MiB DDR carveout (m_axi = REMAP_BASE + (phys & ADDR_MASK)),
// and the TB's AXI slave subtracts REMAP_BASE so the MemModel index it presents is
// (phys & 0x0FFFFFFF). The image loader and the int-0x80 syscall EMULATOR, however,
// dereference RAW guest addresses. For guest addresses >= 0x1000_0000 (the user
// stack lives at 0x40c3_xxxx) the two disagree: the core writes/reads MM[masked]
// while the emulator touched MM[raw], so set_thread_area read a zero user_desc,
// never allocated entry 6, and glibc loaded %gs=0xfffb (flat) -> `call *%gs:0x10`
// (the AT_SYSINFO __kernel_vsyscall gate) -> NULL -> derail. Folding here makes the
// loader + emulator + core agree on ONE index, EXACTLY like the board's
// mem_carveout.cpp (s_mask=0x0FFFFFFF). No-op for the core path (already masked) and
// for addresses < 0x1000_0000 (code/data), and inert when !VEN_KV260_SOC.
// Scoped to the KV260 PS-proxy (userspace Quake) build: that path stages the guest
// user stack at 0x40c3_xxxx (>= 0x1000_0000), where the loader/emulator's raw index
// and the core's masked index diverge. The DOS path (VEN_KV260_SOC without
// VEN_PS_PROXY) is left byte-for-byte unchanged.
#if defined(VEN_KV260_SOC) && defined(VEN_PS_PROXY)
static constexpr uint32_t CARVEOUT_MASK = 0x0FFFFFFFu;   // == ventium_l1_axi ADDR_MASK
static inline uint32_t fold(uint32_t a) { return a & CARVEOUT_MASK; }
#else
static inline uint32_t fold(uint32_t a) { return a; }
#endif

// VEN_RAM_TOP_MB: bound the backed RAM to N MiB, exactly like qemu `-m N`. Above the
// top (but below the 0xFFFE_0000 4G-top BIOS alias) reads return 0xFF (open bus) and
// writes are dropped -- so a guest's write-then-read RAM PROBE (CWSDPMI / Win95 IO.SYS
// finding the top of physical memory) FAILS there instead of finding phantom RAM in the
// sparse model. Phantom RAM over-sizes the DPMI host's page tables, shifting its
// real-mode block up (+0x119 paras) -> over-relocated go32 stub -> #UD (DEBUG_JUN27 23ap).
// Unset (0) = unlimited (tb_main's high-load ELF tests at 0x0804_8000 etc. unchanged).
static inline uint32_t ram_top_bytes() {
    static uint32_t t = []() -> uint32_t {
        const char* e = std::getenv("VEN_RAM_TOP_MB");
        return e ? (uint32_t)(std::strtoul(e, nullptr, 10) * 0x100000u) : 0u;
    }();
    return t;
}
static inline bool above_ram(uint32_t a) {
    uint32_t t = ram_top_bytes();
    // hole between RAM top and the BIOS 4G alias. The alias starts at 0xFFFE0000 for a
    // 128KB BIOS but at 0xFFFC0000 for a 256KB BIOS (bios-256k.bin) -- use the lower bound
    // so the 256KB alias's low half (0xFFFC0000-0xFFFDFFFF) is NOT mistaken for open bus
    // (that made SeaBIOS read garbage from its own 4G-top image and hang early in POST).
    return t && a >= t && a < 0xFFFC0000u;
}

MemModel::Page& MemModel::page_for(uint32_t addr) {
    uint32_t pidx = addr >> PAGE_SHIFT;
    Page& pg = pages_[pidx];                  // default-constructs (zeroed) if absent
    // keep the read cache coherent: if it holds this index (possibly as "absent"),
    // refresh the pointer so a later read sees the now-present page.
    if (cache_valid_ && cache_pidx_ == pidx) cache_page_ = &pg;
    return pg;
}

const MemModel::Page* MemModel::page_lookup(uint32_t addr) const {
    uint32_t pidx = addr >> PAGE_SHIFT;
    if (cache_valid_ && cache_pidx_ == pidx) return cache_page_;   // hot path: no find()
    auto it = pages_.find(pidx);
    const Page* p = (it == pages_.end()) ? nullptr : &it->second;
    cache_pidx_ = pidx; cache_page_ = p; cache_valid_ = true;
    return p;
}

uint8_t MemModel::read8(uint32_t addr) const {
    addr = fold(addr);
    if (above_ram(addr)) return 0xFFu;        // above configured RAM -> open bus (like qemu)
    const Page* p = page_lookup(addr);
    return p ? p->b[addr & PAGE_MASK] : 0u;   // unmapped reads as 0 (M0)
}

void MemModel::write8(uint32_t addr, uint8_t val) {
    addr = fold(addr);
    if (above_ram(addr)) return;              // above configured RAM -> dropped (no phantom RAM)
    page_for(addr).b[addr & PAGE_MASK] = val;
}

uint32_t MemModel::read32(uint32_t addr) const {
    addr = fold(addr);
    if (above_ram(addr)) return 0xFFFFFFFFu;   // above configured RAM -> open bus (like qemu)
    uint32_t off = addr & PAGE_MASK;
    if (off <= PAGE_SIZE - 4) {                 // 4 bytes in one page: a SINGLE lookup
        const Page* p = page_lookup(addr);
        if (!p) return 0u;                      // unmapped reads as 0 (M0)
        const uint8_t* b = &p->b[off];
        return  (uint32_t)b[0]
             | ((uint32_t)b[1] << 8)
             | ((uint32_t)b[2] << 16)
             | ((uint32_t)b[3] << 24);
    }
    // rare page-crossing word: byte-wise (read8 re-folds, harmless)
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

// ---- checkpoint snapshot / restore -----------------------------------------
// Format: [u32 magic][u32 npages] then npages * ([u32 pagenum][4096 bytes]).
void MemModel::snapshot(FILE* f) const {
    uint32_t magic = 0x564D454Du;   // 'VMEM'
    uint32_t np = (uint32_t)pages_.size();
    std::fwrite(&magic, 4, 1, f);
    std::fwrite(&np, 4, 1, f);
    for (const auto& kv : pages_) {
        uint32_t pn = kv.first;
        std::fwrite(&pn, 4, 1, f);
        std::fwrite(kv.second.b, 1, PAGE_SIZE, f);
    }
}
void MemModel::restore(FILE* f) {
    uint32_t magic = 0, np = 0;
    if (std::fread(&magic, 4, 1, f) != 1 || magic != 0x564D454Du) return;
    if (std::fread(&np, 4, 1, f) != 1) return;
    pages_.clear();
    cache_valid_ = false; cache_page_ = nullptr; cache_pidx_ = ~0u;  // stale after clear
    for (uint32_t i = 0; i < np; ++i) {
        uint32_t pn = 0;
        if (std::fread(&pn, 4, 1, f) != 1) break;
        Page pg;
        if (std::fread(pg.b, 1, PAGE_SIZE, f) != PAGE_SIZE) break;
        pages_[pn] = pg;
    }
}

}  // namespace ventium
