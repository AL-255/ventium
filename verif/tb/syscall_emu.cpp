// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/tb/syscall_emu.cpp — see syscall_emu.h.

#include "syscall_emu.h"

#include <cstdlib>
#include <cstring>

namespace ventium {

static const bool kEmuDbg = (std::getenv("SYSCALL_EMU_DEBUG") != nullptr);

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
    // misc + socket family (i386). The socket calls are STUBBED to fail so Quake's
    // UDP net init gives up and falls back to the loopback driver (demos still
    // play); the rest return benign values.
    NR_gettid = 224, NR_getuid32 = 199, NR_geteuid32 = 201, NR_getgid32 = 200,
    NR_getegid32 = 202, NR_socketcall = 102, NR_socket = 359, NR_bind = 361,
    NR_connect = 362, NR_listen = 363, NR_getsockname = 367, NR_getpeername = 368,
    NR_setsockopt = 366, NR_getsockopt = 365, NR_sendto = 369, NR_recvmsg = 372,
    NR_sendmsg = 370, NR_shutdown = 373, NR_poll = 168, NR_select = 142,
    NR_nanosleep = 162, NR_sched_yield = 158, NR_madvise = 219, NR_fchmod = 94,
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
std::string SyscallEmulator::read_cstr(uint32_t addr) const {
    std::string s;
    for (uint32_t i = 0; i < 4096; ++i) {
        uint8_t c = mem_.read8(addr + i);
        if (c == 0) break;
        s.push_back((char)c);
    }
    return s;
}

SyscallEmuResult SyscallEmulator::service(uint32_t nr, uint32_t ebx, uint32_t ecx,
                                          uint32_t edx, uint32_t esi, uint32_t edi,
                                          uint32_t ebp) {
    (void)esi; (void)edi; (void)ebp;
    SyscallEmuResult r;
    ++n_;

    // Synthetic monotonic clock: track the RTL cycle count at 60 MHz (1 cycle =
    // 16.667 ns) so a long compute shows a realistic elapsed time, with a +1ms
    // per-call floor so it strictly advances even when cycles_ is flat (keeps any
    // wall-clock-polling loop terminating).
    vns_ += 1000000ull;   // +1 ms floor
    const uint64_t cyc_ns = (cycles_ * 50ull) / 3ull;     // cycles / 60e6 * 1e9
    const uint64_t now  = cyc_ns > vns_ ? cyc_ns : vns_;
    const uint64_t sec  = now / 1000000000ull;
    const uint64_t nsec = now % 1000000000ull;

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
    case NR_fcntl64:         r.eax = 0;    break;
    case NR_access:          r.eax = ERR(2);  break;       // -ENOENT
    case NR_close: {
        if ((int)ebx == video_fd_) { video_fd_ = -1; r.eax = 0; break; }
        auto it = hostfd_.find((int)ebx);
        if (it != hostfd_.end()) { std::fclose(it->second); hostfd_.erase(it); }
        r.eax = 0; break;
    }
    case NR_open:
    case NR_openat: {
        // open(path=ebx,...) ; openat(dirfd=ebx, path=ecx, ...)
        uint32_t pathp = (nr == NR_openat) ? ecx : ebx;
        std::string path = read_cstr(pathp);
        if (!video_path_.empty() && path == video_path_) {
            video_fd_ = next_fd_++; r.eax = (uint32_t)video_fd_; break;  // capture frames
        }
        FILE* f = std::fopen(path.c_str(), "rb");   // guest paths ARE real host paths
        if (kEmuDbg) std::fprintf(stderr, "[emu] open(\"%s\") -> %s\n",
                                  path.c_str(), f ? "ok" : "ENOENT");
        if (!f) { r.eax = ERR(2); break; }
        int fd = next_fd_++; hostfd_[fd] = f; r.eax = (uint32_t)fd; break;
    }
    case NR_lseek: {
        auto it = hostfd_.find((int)ebx);            // lseek(fd, off=ecx, whence=edx)
        if (it == hostfd_.end()) { r.eax = 0; break; }
        std::fseek(it->second, (long)(int32_t)ecx,
                   edx == 1 ? SEEK_CUR : edx == 2 ? SEEK_END : SEEK_SET);
        r.eax = (uint32_t)std::ftell(it->second); break;
    }
    case NR__llseek: {                               // (fd,hi=ecx,lo=edx,result=esi,whence=edi)
        auto it = hostfd_.find((int)ebx);
        if (it == hostfd_.end()) { r.eax = ERR(9); break; }
        std::fseek(it->second, (long)(int32_t)edx,
                   edi == 1 ? SEEK_CUR : edi == 2 ? SEEK_END : SEEK_SET);
        if (esi) wr64(esi, (uint64_t)std::ftell(it->second));
        r.eax = 0; break;
    }

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
        if (kEmuDbg) std::fprintf(stderr, "[emu] mmap2(len=%u,prot=%u,flags=0x%x,fd=%d,pgoff=%u)\n",
                                  ecx, edx, esi, fd, ebp);
        if (fd >= 0) {
            // file-backed mmap: read the file region into the returned memory so
            // a guest that mmaps a data file (e.g. Quake mmapping pak0.pak) sees
            // its contents. Place it in the anon arena (or honour MAP_FIXED).
            auto it = hostfd_.find(fd);
            uint32_t addr = ((flags & 0x10) && ebx) ? ebx : (mmap_next_ += page_up(ecx ? ecx : PAGE), mmap_next_ - page_up(ecx ? ecx : PAGE));
            if (it != hostfd_.end()) {
                long cur = std::ftell(it->second);
                std::fseek(it->second, (long)ebp * 4096, SEEK_SET);   // pgoff is in pages
                std::vector<uint8_t> buf(ecx);
                size_t got = std::fread(buf.data(), 1, ecx, it->second);
                for (size_t i = 0; i < got; ++i) mem_.write8(addr + (uint32_t)i, buf[i]);
                std::fseek(it->second, cur, SEEK_SET);
            }
            r.eax = addr; break;
        }
        uint32_t addr;
        if ((flags & 0x10) && ebx) addr = ebx;               // MAP_FIXED
        else { addr = mmap_next_; mmap_next_ += page_up(len ? len : PAGE); }
        // anonymous => kernel-zeroed; MemModel reads unmapped as 0, so nothing to do.
        r.eax = addr;
        break;
    }

    case NR_read: {
        auto it = hostfd_.find((int)ebx);            // read(fd=ebx, buf=ecx, cnt=edx)
        if (it != hostfd_.end()) {
            std::vector<uint8_t> buf(edx);
            size_t got = std::fread(buf.data(), 1, edx, it->second);
            for (size_t i = 0; i < got; ++i) mem_.write8(ecx + (uint32_t)i, buf[i]);
            if (kEmuDbg) std::fprintf(stderr, "[emu] read(fd=%u,cnt=%u)->%zu first=%02x%02x%02x%02x\n",
                ebx, edx, got, got>0?buf[0]:0, got>1?buf[1]:0, got>2?buf[2]:0, got>3?buf[3]:0);
            r.eax = (uint32_t)got; break;
        }
        if (kEmuDbg) std::fprintf(stderr, "[emu] read(fd=%u,cnt=%u) NON-HOST-FD (stdin path)\n", ebx, edx);
        uint32_t n = 0;                              // else: fd 0 = our stdin feed
        while (n < edx && stdin_pos_ < stdin_.size())
            mem_.write8(ecx + n++, stdin_[stdin_pos_++]);
        r.eax = n;
        break;
    }
    case NR_readv: {
        // readv(fd=ebx, iov=ecx, cnt=edx). musl's buffered fread() goes through
        // here, so it MUST read host files (not just our stdin feed).
        auto it = hostfd_.find((int)ebx);
        uint32_t total = 0;
        for (uint32_t i = 0; i < edx; ++i) {
            uint32_t base = mem_.read32(ecx + i * 8);
            uint32_t len  = mem_.read32(ecx + i * 8 + 4);
            if (it != hostfd_.end()) {
                std::vector<uint8_t> buf(len);
                size_t got = std::fread(buf.data(), 1, len, it->second);
                for (size_t k = 0; k < got; ++k) mem_.write8(base + (uint32_t)k, buf[k]);
                total += (uint32_t)got;
                if (got < len) break;               // short read -> EOF
            } else {
                uint32_t k = 0;                      // fd 0 = our stdin feed
                while (k < len && stdin_pos_ < stdin_.size())
                    mem_.write8(base + k++, stdin_[stdin_pos_++]);
                total += k;
                if (stdin_pos_ >= stdin_.size()) break;
            }
        }
        if (kEmuDbg) std::fprintf(stderr, "[emu] readv(fd=%u,cnt=%u)->%u\n", ebx, edx, total);
        r.eax = total;
        break;
    }
    case NR_write: {
        if ((int)ebx == video_fd_) {                 // Quake frame stream -> capture
            auto b = rd(ecx, edx);
            video_.insert(video_.end(), b.begin(), b.end());
        } else if (ebx == 1 || ebx == 2) {
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
            auto b = rd(base, len);
            if ((int)ebx == video_fd_) video_.insert(video_.end(), b.begin(), b.end());
            else if (ebx == 1 || ebx == 2)
                out_.append(reinterpret_cast<const char*>(b.data()), b.size());
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
        // struct stat64 (96 bytes on i386): st_mode @16, st_size @44 (8 bytes).
        // For a real host fd, report S_IFREG + the true size (Quake needs the pak
        // size); otherwise a char device (so stdio treats fd 1 as a tty).
        for (int i = 0; i < 96; ++i) mem_.write8(ecx + i, 0);
        auto it = (nr == NR_fstat64) ? hostfd_.find((int)ebx) : hostfd_.end();
        if (it != hostfd_.end()) {
            long cur = std::ftell(it->second);
            std::fseek(it->second, 0, SEEK_END);
            long sz = std::ftell(it->second);
            std::fseek(it->second, cur, SEEK_SET);
            wr32(ecx + 16, 0x81a4);            // st_mode = S_IFREG|0644
            wr64(ecx + 44, (uint64_t)sz);      // st_size
        } else {
            wr32(ecx + 16, 0x2190);            // st_mode = S_IFCHR|0660
        }
        r.eax = 0; break;
    }
    case NR_getrandom: {
        for (uint32_t i = 0; i < edx; ++i) mem_.write8(ebx + i, 0);  // deterministic
        r.eax = edx; break;
    }

    // --- misc benign returns ---
    case NR_gettid:          r.eax = 1000; break;
    case NR_getuid32: case NR_geteuid32:
    case NR_getgid32: case NR_getegid32: r.eax = 0; break;   // uid/gid 0 (root)
    case NR_sched_yield:     r.eax = 0; break;
    case NR_madvise:         r.eax = 0; break;
    case NR_fchmod:          r.eax = 0; break;
    case NR_poll:            r.eax = 0; break;   // 0 fds ready (no net/input)
    case NR_select:          r.eax = 0; break;
    case NR_nanosleep:       r.eax = 0; break;   // return immediately (synthetic time)

    // --- socket family: STUB as failed so Quake's UDP init falls back to loopback ---
    case NR_socket: case NR_socketcall: case NR_bind: case NR_connect:
    case NR_listen: case NR_getsockname: case NR_getpeername: case NR_setsockopt:
    case NR_getsockopt: case NR_sendto: case NR_recvmsg: case NR_sendmsg:
    case NR_shutdown:        r.eax = ERR(97); break;   // -EAFNOSUPPORT

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
