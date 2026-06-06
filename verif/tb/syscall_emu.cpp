// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/tb/syscall_emu.cpp — see syscall_emu.h.

#include "syscall_emu.h"

#include <cstring>

namespace ventium {

// i386 Linux syscall numbers (the subset the P5 benchmark + Quake corpus issues;
// enumerated with qemu-i386 -strace).
enum : uint32_t {
    NR_exit = 1, NR_read = 3, NR_write = 4, NR_open = 5, NR_close = 6,
    NR_time = 13, NR_lseek = 19, NR_getpid = 20, NR_access = 33, NR_brk = 45,
    NR_ioctl = 54, NR_gettimeofday = 78, NR_munmap = 91, NR_uname = 122,
    NR_mprotect = 125, NR__llseek = 140, NR_readv = 145, NR_writev = 146,
    NR_rt_sigaction = 174, NR_rt_sigprocmask = 175, NR_mmap2 = 192,
    NR_stat64 = 195, NR_fstat64 = 197, NR_fcntl64 = 221, NR_set_thread_area = 243,
    NR_exit_group = 252, NR_set_tid_address = 258, NR_clock_gettime = 265,
    NR_clock_getres = 266, NR_openat = 295, NR_getrandom = 355, NR_statx = 383,
    NR_clock_gettime64 = 403, NR_clock_getres_time64 = 406,
};

static inline uint32_t ERR(int e) { return (uint32_t)(-e); }   // -errno
static const uint32_t PAGE = 0x1000;
static inline uint32_t page_up(uint32_t x) { return (x + PAGE - 1) & ~(PAGE - 1); }

SyscallEmulator::SyscallEmulator(MemModel& mem, std::vector<uint8_t> stdin_bytes,
                                 uint32_t brk_base)
    : mem_(mem), stdin_(std::move(stdin_bytes)),
      brk_(page_up(brk_base)),
      // A high private arena for anon mmap, clear of the program (low), the brk
      // heap (just above the image), and the initial stack (~0x40c34000).
      mmap_next_(0x50000000u),
      vns_(1000000000ull) {}   // start at t=1.000000000s

std::vector<uint8_t> SyscallEmulator::rd(uint32_t addr, uint32_t len) const {
    std::vector<uint8_t> v;
    v.reserve(len);
    for (uint32_t i = 0; i < len; ++i) v.push_back(mem_.read8(addr + i));
    return v;
}
void SyscallEmulator::wr(uint32_t addr, const uint8_t* p, uint32_t len) {
    for (uint32_t i = 0; i < len; ++i) mem_.write8(addr + i, p[i]);
}
void SyscallEmulator::wr32(uint32_t addr, uint32_t v) { mem_.write32(addr, v); }
void SyscallEmulator::wr64(uint32_t addr, uint64_t v) {
    mem_.write32(addr, (uint32_t)v);
    mem_.write32(addr + 4, (uint32_t)(v >> 32));
}

SyscallEmuResult SyscallEmulator::service(uint32_t nr, uint32_t ebx, uint32_t ecx,
                                          uint32_t edx, uint32_t esi, uint32_t edi,
                                          uint32_t ebp) {
    (void)esi; (void)edi; (void)ebp;
    SyscallEmuResult r;
    ++n_;

    // advance the synthetic monotonic clock on EVERY syscall (so any timer poll
    // makes progress regardless of which time call it uses).
    vns_ += 1000000ull;   // +1 ms
    const uint64_t sec  = vns_ / 1000000000ull;
    const uint64_t nsec = vns_ % 1000000000ull;

    switch (nr) {
    case NR_set_thread_area: {
        // user_desc @ ebx: entry_number(0,4), base_addr(4,4), limit(8,4), flags(12,4)
        uint32_t entry = mem_.read32(ebx);
        uint32_t base  = mem_.read32(ebx + 4);
        // -1 => "allocate a free entry". MUST allocate entry 6 first: musl then
        // loads %gs with selector (6<<3)|3 = 0x33, and the core ONLY installs the
        // latched gs_base on a `mov gs,0x33` (core.sv: any other selector stays
        // flat, base=0). qemu allocates 6 too. Getting this wrong leaves %gs flat,
        // so musl's `call *%gs:0x10` (the __kernel_vsyscall gate) reads 0 -> NULL.
        if (entry == 0xffffffffu) { static uint32_t next = 6; entry = next++; wr32(ebx, entry); }
        r.apply_gs = true; r.gs_base = base; r.eax = 0;
        break;
    }
    case NR_set_tid_address: r.eax = 1000; break;          // a fixed tid
    case NR_getpid:          r.eax = 1000; break;
    case NR_ioctl:           r.eax = 0;    break;          // pretend success (tty)
    case NR_rt_sigaction:
    case NR_rt_sigprocmask:  r.eax = 0;    break;
    case NR_mprotect:        r.eax = 0;    break;
    case NR_munmap:          r.eax = 0;    break;
    case NR_close:           r.eax = 0;    break;
    case NR_fcntl64:         r.eax = 0;    break;
    case NR_lseek:
    case NR__llseek:         r.eax = 0;    break;
    case NR_access:          r.eax = ERR(2);  break;       // -ENOENT
    case NR_open:
    case NR_openat:          r.eax = ERR(2);  break;       // -ENOENT (no FS)

    case NR_brk: {
        if (ebx == 0) { r.eax = brk_; }
        else if (ebx >= brk_) { brk_ = ebx; r.eax = brk_; }  // grow
        else { r.eax = brk_; }                               // shrink: keep (benign)
        break;
    }
    case NR_mmap2: {
        const uint32_t len   = ecx;
        const uint32_t flags = esi;
        const int32_t  fd    = (int32_t)edi;
        if (fd >= 0) { r.unsupported = true; break; }        // file-backed: not yet
        uint32_t addr;
        if ((flags & 0x10) && ebx) addr = ebx;               // MAP_FIXED
        else { addr = mmap_next_; mmap_next_ += page_up(len ? len : PAGE); }
        // anonymous => kernel-zeroed; MemModel reads unmapped as 0, so nothing to do.
        r.eax = addr;
        break;
    }

    case NR_read: {
        uint32_t n = 0;
        while (n < edx && stdin_pos_ < stdin_.size())
            mem_.write8(ecx + n++, stdin_[stdin_pos_++]);
        r.eax = n;
        break;
    }
    case NR_readv: {
        uint32_t total = 0;
        for (uint32_t i = 0; i < edx; ++i) {
            uint32_t base = mem_.read32(ecx + i * 8);
            uint32_t len  = mem_.read32(ecx + i * 8 + 4);
            uint32_t k = 0;
            while (k < len && stdin_pos_ < stdin_.size())
                mem_.write8(base + k++, stdin_[stdin_pos_++]);
            total += k;
            if (stdin_pos_ >= stdin_.size()) break;
        }
        r.eax = total;
        break;
    }
    case NR_write: {
        if (ebx == 1 || ebx == 2) {
            auto b = rd(ecx, edx);
            out_.append(reinterpret_cast<const char*>(b.data()), b.size());
        }
        r.eax = edx;
        break;
    }
    case NR_writev: {
        uint32_t total = 0;
        for (uint32_t i = 0; i < edx; ++i) {
            uint32_t base = mem_.read32(ecx + i * 8);
            uint32_t len  = mem_.read32(ecx + i * 8 + 4);
            if (ebx == 1 || ebx == 2) {
                auto b = rd(base, len);
                out_.append(reinterpret_cast<const char*>(b.data()), b.size());
            }
            total += len;
        }
        r.eax = total;
        break;
    }

    case NR_gettimeofday: {
        if (ebx) { wr32(ebx, (uint32_t)sec); wr32(ebx + 4, (uint32_t)(nsec / 1000)); }
        r.eax = 0; break;
    }
    case NR_time: {
        if (ebx) wr32(ebx, (uint32_t)sec);
        r.eax = (uint32_t)sec; break;
    }
    case NR_clock_gettime: {
        if (ecx) { wr32(ecx, (uint32_t)sec); wr32(ecx + 4, (uint32_t)nsec); }
        r.eax = 0; break;
    }
    case NR_clock_gettime64: {
        if (ecx) { wr64(ecx, sec); wr64(ecx + 8, nsec); }
        r.eax = 0; break;
    }
    case NR_clock_getres: {
        if (ecx) { wr32(ecx, 0); wr32(ecx + 4, 1); }       // 1 ns resolution
        r.eax = 0; break;
    }
    case NR_clock_getres_time64: {
        if (ecx) { wr64(ecx, 0); wr64(ecx + 8, 1); }
        r.eax = 0; break;
    }

    case NR_uname: {
        // struct utsname = 6 fields of 65 bytes. Canned, deterministic.
        const char* f[6] = {"Linux", "ventium", "5.0.0-ventium",
                            "#1 SMP ventium", "i686", "(none)"};
        for (int i = 0; i < 6; ++i) {
            for (int j = 0; j < 65; ++j)
                mem_.write8(ebx + i * 65 + j, j < (int)std::strlen(f[i]) ? f[i][j] : 0);
        }
        r.eax = 0; break;
    }
    case NR_fstat64:
    case NR_stat64: {
        // zero a struct stat64 (96 bytes on i386) at the buffer, set st_mode to a
        // char device so stdio treats fd 1 as a tty (line-buffered). For fstat64
        // ebx=fd, ecx=buf; for stat64 ebx=path, ecx=buf.
        for (int i = 0; i < 96; ++i) mem_.write8(ecx + i, 0);
        wr32(ecx + 16, 0x2190);    // st_mode = S_IFCHR|0660
        r.eax = 0; break;
    }
    case NR_getrandom: {
        for (uint32_t i = 0; i < edx; ++i) mem_.write8(ebx + i, 0);  // deterministic
        r.eax = edx; break;
    }

    case NR_exit:
    case NR_exit_group:
        r.should_exit = true; r.exit_code = (int)(ebx & 0xff); r.eax = 0;
        break;

    default:
        r.unsupported = true;
        break;
    }
    return r;
}

}  // namespace ventium
