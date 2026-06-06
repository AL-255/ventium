// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/tb/syscall_emu.h
//
// M14 free-run syscall EMULATOR (the endurance complement to the M7.1 replay).
//
// In --emulate-syscalls mode the TB does NOT replay a golden's recorded int-0x80
// effects; it EMULATES the i386 Linux syscall directly against its own MemModel,
// exactly as a kernel would, so the Ventium RTL can execute an arbitrary
// linux-user static ELF to COMPLETION at full Verilator speed (~45k insn/s) with
// no gdbstub oracle in the loop. The correctness oracle then becomes the program
// itself: its captured stdout must equal qemu-i386's for the same args (the
// benchmarks self-validate — coremark's CRCs/"validated", dhrystone's final
// values, linpack's residual, whetstone's results), modulo timing-only lines.
//
// Determinism: time syscalls return a synthetic MONOTONIC clock (advances each
// call) so wall-clock-polling loops (linpack's timer) terminate; the reported
// seconds differ from qemu's real clock (that diff is masked at grade time), but
// every DATA result is environment-independent and must match bit-for-bit.
//
// Only the syscall set the P5 benchmark + Quake corpus actually issues is
// implemented (enumerated via qemu -strace). An UNIMPLEMENTED syscall is a LOUD
// stop (never a silent wrong answer) — see service().
#ifndef VENTIUM_SYSCALL_EMU_H
#define VENTIUM_SYSCALL_EMU_H

#include <cstdint>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#include "memmodel.h"

namespace ventium {

// Result of emulating one int-0x80, driven back into the core combinationally.
struct SyscallEmuResult {
    uint32_t eax        = 0;       // -> syscall_eax (the kernel return value)
    bool     apply_gs   = false;   // -> syscall_apply_gs (set_thread_area)
    uint32_t gs_base    = 0;       // -> syscall_gs_base
    bool     should_exit = false;  // exit_group/exit -> stop the run
    int      exit_code  = 0;
    bool     unsupported = false;  // an unimplemented syscall (LOUD stop)
};

class SyscallEmulator {
public:
    // mem: the TB's memory model (the kernel writes land here). stdin_bytes: the
    // bytes a guest read() consumes (e.g. linpack's "100\nq\n"). brk_base: the
    // initial program break (page-aligned end of the loaded image).
    SyscallEmulator(MemModel& mem, std::vector<uint8_t> stdin_bytes,
                    uint32_t brk_base);

    // Emulate the syscall nr=eax with i386 args (ebx,ecx,edx,esi,edi,ebp).
    SyscallEmuResult service(uint32_t nr, uint32_t ebx, uint32_t ecx,
                             uint32_t edx, uint32_t esi, uint32_t edi,
                             uint32_t ebp);

    // Drive the synthetic clock off the RTL cycle count (set before each
    // service()): time syscalls then report cycles / 60 MHz, so a long compute
    // shows a realistic elapsed time (coremark's >=10s validity check passes and
    // it prints "Correct operation validated", matching qemu). The exact seconds
    // differ from qemu's host clock (masked at grade time); only that it elapses.
    void               set_cycles(uint64_t c) { cycles_ = c; }

    // Real host file I/O (so a guest can open/read/lseek/fstat actual files,
    // e.g. Quake's pak0.pak). The guest paths are real host paths (the loader's
    // -basedir is a host path), so we open them directly, read-only.
    // The video stream: if the guest opens video_path (Quake's $P5Q_VIDEO FIFO),
    // its writes are CAPTURED here instead of going to a pipe (the P5Q1 frame
    // stream: magic+w+h, then per-frame palette[768]+pixels[w*h]).
    void               set_video_path(const std::string& p) { video_path_ = p; }
    const std::vector<uint8_t>& video() const { return video_; }

    // Everything the guest wrote to fd 1/2, in order (the graded output).
    const std::string& captured_stdout() const { return out_; }
    uint64_t           syscalls_serviced() const { return n_; }

private:
    std::string          read_cstr(uint32_t addr) const;   // NUL-terminated guest string

    // memory helpers (little-endian guest)
    std::vector<uint8_t> rd(uint32_t addr, uint32_t len) const;
    void                 wr(uint32_t addr, const uint8_t* p, uint32_t len);
    void                 wr32(uint32_t addr, uint32_t v);
    void                 wr64(uint32_t addr, uint64_t v);

    MemModel&            mem_;
    std::vector<uint8_t> stdin_;
    size_t               stdin_pos_ = 0;
    uint32_t             brk_;            // current program break
    uint32_t             mmap_next_;      // bump pointer for anon mmap
    uint64_t             vns_;            // synthetic monotonic clock (ns) — per-call floor
    uint64_t             cycles_ = 0;     // RTL cycle count (drives the wall clock)
    std::string          out_;            // captured fd 1/2 output
    uint64_t             n_ = 0;          // syscalls serviced
    // host file I/O + video capture
    std::map<int, FILE*> hostfd_;         // guest fd -> host file
    int                  next_fd_ = 16;   // next guest fd to hand out
    std::string          video_path_;     // the $P5Q_VIDEO path (captured, not opened)
    int                  video_fd_ = -1;  // guest fd bound to the video stream
    std::vector<uint8_t> video_;          // captured P5Q1 frame stream
};

}  // namespace ventium
#endif  // VENTIUM_SYSCALL_EMU_H
