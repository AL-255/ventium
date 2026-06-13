// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/mem_carveout.cpp — the BOARD backing for ventium::MemModel.
//
// The cosim's MemModel (verif/tb/memmodel.cpp) is a sparse 4 KiB-page hash map.
// On the board, the guest's memory IS the reserved DDR carveout the core's
// L1/AXI master reads, so we provide an ALTERNATE implementation of the four
// MemModel byte/word accessors that the ported syscall emulator + image loader
// use — backed by the mmap'd carveout (g_ddr) with the same x86-phys -> carveout
// fold the L1AXI master applies (ddr = REMAP_BASE + (phys & ADDR_MASK);
// ventium_l1_axi.sv). verif/tb/memmodel.cpp is NOT compiled on the board, so
// these definitions are the ones that link. The remaining MemModel methods
// (load_image / service / snapshot / restore) are never referenced by the
// syscall_emu / quake_image translation units, so they need no board definition.
//
// This keeps the shared verif/tb sources byte-identical (no fork): only the
// accessor BODIES change, via the include path resolving to verif/tb/memmodel.h.

#include "memmodel.h"   // verif/tb/memmodel.h (the class declaration), via -I

namespace ventium {

// The mmap'd carveout base + the ADDR_MASK fold (set once at init from the PS).
// A single carveout backs every MemModel instance, so file-scope globals are the
// natural home (the MemModel object itself carries no per-instance storage here).
static volatile uint8_t* s_base = nullptr;
static uint32_t          s_mask = 0x0FFFFFFFu;   // 256 MiB carveout (ventium_l1_axi)

void mem_carveout_bind(volatile uint8_t* base, uint32_t mask) {
    s_base = base;
    s_mask = mask;
}

// Each guest byte is folded independently (mask per byte) so an access near the
// 256 MiB boundary wraps exactly as the L1AXI master's per-address fold does.
uint8_t MemModel::read8(uint32_t a) const {
    return s_base[a & s_mask];
}
void MemModel::write8(uint32_t a, uint8_t v) {
    s_base[a & s_mask] = v;
}
uint32_t MemModel::read32(uint32_t a) const {
    return  (uint32_t)s_base[ a      & s_mask]
         | ((uint32_t)s_base[(a + 1) & s_mask] << 8)
         | ((uint32_t)s_base[(a + 2) & s_mask] << 16)
         | ((uint32_t)s_base[(a + 3) & s_mask] << 24);
}
void MemModel::write32(uint32_t a, uint32_t v) {
    s_base[ a      & s_mask] = (uint8_t) v;
    s_base[(a + 1) & s_mask] = (uint8_t)(v >> 8);
    s_base[(a + 2) & s_mask] = (uint8_t)(v >> 16);
    s_base[(a + 3) & s_mask] = (uint8_t)(v >> 24);
}

}  // namespace ventium
