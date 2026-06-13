// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/ven_quake.cpp — the C++ glue between the C ven_soc_app and
// the ported (unmodified) verif/tb syscall emulator + Quake image loader. See
// ven_quake.h for the C ABI. The MemModel is backed by the DDR carveout
// (mem_carveout.cpp), so the emulator's kernel memory effects land directly in
// the memory the core's L1/AXI master reads.

#include "ven_quake.h"

#include <cstdio>
#include <vector>

#include "syscall_emu.h"    // verif/tb/syscall_emu.h (via -I)
#include "quake_image.h"    // verif/tb/quake_image.h (via -I)
#include "memmodel.h"       // verif/tb/memmodel.h   (via -I)

// Provided by mem_carveout.cpp.
namespace ventium { void mem_carveout_bind(volatile uint8_t* base, uint32_t mask); }

static ventium::MemModel*        g_mem  = nullptr;
static ventium::SyscallEmulator* g_emu  = nullptr;
static size_t                    g_vcur = 0;   // video drain cursor

extern "C" int ven_quake_init(volatile uint8_t* ddr, uint32_t mask,
                              const char* image_json, const char* video_path,
                              uint32_t brk_base, uint32_t* out_eip,
                              uint32_t* out_esp) {
    ventium::mem_carveout_bind(ddr, mask);
    g_mem = new ventium::MemModel();
    // Stage every materialised region of the process image into the carveout
    // (the loader writes via MemModel::write8 -> g_ddr). Zero regions stay sparse
    // (the carveout is zeroed). Returns the reset regs.
    ventium::QuakeImage img = ventium::load_quake_image(image_json, *g_mem);
    if (!img.ok) {
        std::fprintf(stderr, "ven_quake: failed to load image '%s'\n", image_json);
        return -1;
    }
    g_emu = new ventium::SyscallEmulator(*g_mem, std::vector<uint8_t>(), brk_base);
    if (video_path && *video_path) g_emu->set_video_path(video_path);
    g_vcur = 0;
    if (out_eip) *out_eip = img.eip;
    if (out_esp) *out_esp = img.esp;
    std::fprintf(stderr, "ven_quake: image staged; entry=0x%08x esp=0x%08x brk=0x%08x video='%s'\n",
                 img.eip, img.esp, brk_base, video_path ? video_path : "(none)");
    return 0;
}

extern "C" void ven_quake_service(uint32_t nr, uint32_t ebx, uint32_t ecx,
                                  uint32_t edx, uint32_t esi, uint32_t edi,
                                  uint32_t ebp, uint64_t cycles,
                                  struct ven_sys_result* res) {
    g_emu->set_cycles(cycles);
    ventium::SyscallEmuResult r = g_emu->service(nr, ebx, ecx, edx, esi, edi, ebp);
    res->eax         = r.eax;
    res->apply_gs    = r.apply_gs ? 1 : 0;
    res->gs_base     = r.gs_base;
    res->should_exit = r.should_exit ? 1 : 0;
    res->exit_code   = r.exit_code;
    res->unsupported = r.unsupported ? 1 : 0;
}

extern "C" uint32_t ven_quake_video_drain(uint8_t* buf, uint32_t max) {
    if (!g_emu) return 0;
    const std::vector<uint8_t>& v = g_emu->video();
    uint32_t n = 0;
    while (g_vcur < v.size() && n < max) buf[n++] = v[g_vcur++];
    return n;
}

extern "C" uint64_t ven_quake_video_total(void) {
    return g_emu ? (uint64_t)g_emu->video().size() : 0;
}
extern "C" uint64_t ven_quake_syscalls(void) {
    return g_emu ? g_emu->syscalls_serviced() : 0;
}
