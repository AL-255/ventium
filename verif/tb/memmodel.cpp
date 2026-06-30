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

// VEN_VGA_OPTROM: serve the std-VGA option ROM (loaded at 0xC0000) at the VGA PCI
// expansion-ROM BAR window (0xFEBE0000, 64KB) so SeaBIOS finds the 0x55AA signature
// and RUNS the VGA BIOS (matching qemu) instead of skipping it. Gated test.
static inline bool vga_optrom_on() {
    static int v = -1;
    if (v < 0) v = std::getenv("VEN_VGA_OPTROM") ? 1 : 0;
    return v;
}
// Stable snapshot of the std-VGA option ROM. The live 0xC0000 copy gets overwritten
// by SeaBIOS POST shadowing before the VGA option-rom scan, so we serve the VGA
// expansion-ROM BAR window (0xFEBE0000) from this snapshot taken at load time.
static uint8_t g_optrom[65536];
static bool    g_optrom_valid = false;

// e1000 PXE option ROM served at the e1000 exp-ROM BAR (0xFEB80000, 256KB window) so
// the option-ROM/UMB layout matches qemu (qemu's e1000 device serves the PXE ROM here;
// without it kvmvapic lands first and the whole layout -> CWSDPMI memory map diverges).
static uint8_t g_e1000rom[262144];
static int     g_e1000_valid = -1;   // -1 untried, 0 absent, 1 loaded
static void load_e1000_rom() {
    if (g_e1000_valid >= 0) return;
    g_e1000_valid = 0;
    const char* p = std::getenv("VEN_E1000_ROM");
    if (!p) return;
    FILE* f = std::fopen(p, "rb");
    if (!f) return;
    size_t n = std::fread(g_e1000rom, 1, sizeof(g_e1000rom), f);
    std::fclose(f);
    if (n == 0) return;
    g_e1000_valid = 1;
    // qemu fixes the option ROM's checksum at load (the raw file carries a placeholder).
    // SeaBIOS rejects a nonzero byte-sum -> a different (bad-checksum) code path that
    // diverges. Adjust the last byte of the declared image (size=ROM[2]*512) so sum==0.
    uint32_t romsz = (uint32_t)g_e1000rom[2] * 512u;
    uint8_t sum = 0;
    for (uint32_t i = 0; i < romsz && i < n; i++) sum = (uint8_t)(sum + g_e1000rom[i]);
    std::fprintf(stderr, "[e1000-rom] loaded n=%zu hdr=%02x%02x sz=%u presum=%02x\n",
                 n, g_e1000rom[0], g_e1000rom[1], romsz, sum);
    if (romsz >= 2 && romsz <= n) {
        g_e1000rom[romsz - 1] = (uint8_t)(g_e1000rom[romsz - 1] - sum);
        uint8_t s2 = 0; for (uint32_t i = 0; i < romsz; i++) s2 = (uint8_t)(s2 + g_e1000rom[i]);
        std::fprintf(stderr, "[e1000-rom] patched last byte -> postsum=%02x\n", s2);
    }
}

uint8_t MemModel::read8(uint32_t addr) const {
    addr = fold(addr);
    if (vga_optrom_on() && g_optrom_valid && (addr & 0xFFFF0000u) == 0xFEBE0000u)
        return g_optrom[addr & 0xFFFFu];
    if (vga_optrom_on() && (addr & 0xFFFC0000u) == 0xFEB80000u) {
        load_e1000_rom();
        if (g_e1000_valid == 1) return g_e1000rom[addr & 0x3FFFFu];
    }
    if (above_ram(addr)) return 0xFFu;        // above configured RAM -> open bus (like qemu)
    const Page* p = page_lookup(addr);
    return p ? p->b[addr & PAGE_MASK] : 0u;   // unmapped reads as 0 (M0)
}

void MemModel::write8(uint32_t addr, uint8_t val) {
    addr = fold(addr);
    if (above_ram(addr)) return;              // above configured RAM -> dropped (no phantom RAM)
    // VEN_MEMWATCH=<linear>: log every NONZERO byte store to the 2 bytes [addr,addr+2)
    // of the watched word. This is the single choke point for ALL memory writes (core,
    // IDE DMA, fw_cfg DMA -- mem.service funnels every master here AFTER the SoC mux/A20),
    // so it catches the [ds:0x426] clobber even if it is not a core-bus store.
    {
        static uint32_t mw = []() -> uint32_t {
            const char* e = std::getenv("VEN_MEMWATCH");
            return e ? (uint32_t)std::strtoul(e, nullptr, 0) : 0;
        }();
        if (mw && addr >= mw && addr < mw + 2 && val)
            std::fprintf(stderr, "[memwr] addr=0x%05x val=0x%02x  (writes_so_far=%llu)\n",
                         addr, val, (unsigned long long)writes_);
    }
    page_for(addr).b[addr & PAGE_MASK] = val;
}

uint32_t MemModel::read32(uint32_t addr) const {
    addr = fold(addr);
    if (vga_optrom_on() && g_optrom_valid && (addr & 0xFFFF0000u) == 0xFEBE0000u) {
        uint32_t o = addr & 0xFFFFu;
        return  (uint32_t)g_optrom[o]
             | ((uint32_t)g_optrom[(o + 1) & 0xFFFF] << 8)
             | ((uint32_t)g_optrom[(o + 2) & 0xFFFF] << 16)
             | ((uint32_t)g_optrom[(o + 3) & 0xFFFF] << 24);
    }
    if (vga_optrom_on() && (addr & 0xFFFC0000u) == 0xFEB80000u) {
        load_e1000_rom();
        if (g_e1000_valid == 1) {
            uint32_t o = addr & 0x3FFFFu;
            return  (uint32_t)g_e1000rom[o]
                 | ((uint32_t)g_e1000rom[(o + 1) & 0x3FFFF] << 8)
                 | ((uint32_t)g_e1000rom[(o + 2) & 0x3FFFF] << 16)
                 | ((uint32_t)g_e1000rom[(o + 3) & 0x3FFFF] << 24);
        }
    }
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
        if (load_addr == 0xC0000u && n < 65536) { g_optrom[n] = (uint8_t)c; g_optrom_valid = true; }
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
