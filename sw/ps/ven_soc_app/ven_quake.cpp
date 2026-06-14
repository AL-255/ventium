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

// ---- debug/observability exports --------------------------------------------
// NR -> name, mirroring the enum in verif/tb/syscall_emu.cpp (kept here so the
// shared emulator source stays byte-identical — no fork).
extern "C" const char* ven_quake_nr_name(uint32_t nr) {
    switch (nr) {
    case 1:   return "exit";
    case 3:   return "read";
    case 4:   return "write";
    case 5:   return "open";
    case 6:   return "close";
    case 13:  return "time";
    case 19:  return "lseek";
    case 20:  return "getpid";
    case 33:  return "access";
    case 45:  return "brk";
    case 54:  return "ioctl";
    case 78:  return "gettimeofday";
    case 91:  return "munmap";
    case 94:  return "fchmod";
    case 102: return "socketcall";
    case 122: return "uname";
    case 125: return "mprotect";
    case 140: return "_llseek";
    case 142: return "select";
    case 145: return "readv";
    case 146: return "writev";
    case 158: return "sched_yield";
    case 162: return "nanosleep";
    case 168: return "poll";
    case 174: return "rt_sigaction";
    case 175: return "rt_sigprocmask";
    case 192: return "mmap2";
    case 195: return "stat64";
    case 197: return "fstat64";
    case 199: return "getuid32";
    case 200: return "getgid32";
    case 201: return "geteuid32";
    case 202: return "getegid32";
    case 219: return "madvise";
    case 221: return "fcntl64";
    case 224: return "gettid";
    case 243: return "set_thread_area";
    case 252: return "exit_group";
    case 258: return "set_tid_address";
    case 265: return "clock_gettime";
    case 266: return "clock_getres";
    case 295: return "openat";
    case 355: return "getrandom";
    case 359: return "socket";
    case 361: return "bind";
    case 362: return "connect";
    case 363: return "listen";
    case 365: return "getsockopt";
    case 366: return "setsockopt";
    case 367: return "getsockname";
    case 368: return "getpeername";
    case 369: return "sendto";
    case 370: return "sendmsg";
    case 372: return "recvmsg";
    case 373: return "shutdown";
    case 383: return "statx";
    case 403: return "clock_gettime64";
    case 406: return "clock_getres_time64";
    default:  return "nr_?";
    }
}

extern "C" int ven_quake_read_cstr(uint32_t gaddr, char* out, int max) {
    if (!g_mem || !out || max <= 0) return 0;
    int i = 0;
    for (; i < max - 1; ++i) {
        uint8_t c = g_mem->read8(gaddr + (uint32_t)i);
        if (c == 0) break;
        out[i] = (c >= 32 && c < 127) ? (char)c : '?';   // printable-safe
    }
    out[i] = '\0';
    return i;
}

extern "C" uint64_t ven_quake_stdout_len(void) {
    return g_emu ? (uint64_t)g_emu->captured_stdout().size() : 0;
}
extern "C" int ven_quake_stdout_copy(uint64_t from, char* out, int max) {
    if (!g_emu || !out || max <= 0) return 0;
    const std::string& s = g_emu->captured_stdout();
    if (from >= s.size()) return 0;
    int n = (int)(s.size() - from);
    if (n > max) n = max;
    for (int i = 0; i < n; ++i) out[i] = s[(size_t)from + (size_t)i];
    return n;
}
