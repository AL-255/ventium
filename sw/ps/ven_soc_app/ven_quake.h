// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/ven_quake.h — C ABI over the ported M14 free-run syscall
// EMULATOR (verif/tb/syscall_emu.cpp) + the Quake process-image loader
// (verif/tb/quake_image.cpp), for the board's userspace-Quake int-0x80 proxy.
//
// On a +VEN_PS_PROXY bitstream the core stalls in S_SYSCALL_WAIT on every cd80;
// the PS reads {nr,args} from the ven_soc_axil 0x40-0x6C window, calls
// ven_quake_service() (which emulates the i386 Linux syscall against the DDR
// carveout the core's L1/AXI master sees), then writes the response + commits.
// This is the exact emulator the cosim free-run (run-quake-fb.sh) proves; only
// the MemModel backing is swapped for direct g_ddr indexing (mem_carveout.cpp).
#ifndef VEN_QUAKE_H
#define VEN_QUAKE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One emulated int-0x80 result, mirroring SyscallEmuResult (syscall_emu.h).
struct ven_sys_result {
    uint32_t eax;          // -> R_SYS_RET -> syscall_eax (kernel return value)
    int      apply_gs;     // 1 = set_thread_area set a new %gs TLS base
    uint32_t gs_base;      // -> R_SYS_GS -> syscall_gs_base
    int      should_exit;  // exit/exit_group -> stop the run
    int      exit_code;
    int      unsupported;  // an unimplemented syscall (LOUD stop)
};

// Bind the mmap'd DDR carveout (the guest's flat x86-phys space, folded by `mask`
// == ADDR_MASK), stage the process image (the gen_trace.py --image-out JSON) into
// it, and build the emulator. `video_path` is the guest's $P5Q_VIDEO sentinel
// (its write() stream is captured as the P5Q1 framebuffer); `brk_base` is the
// initial program break (page-aligned end of the loaded image). On success
// returns 0 and fills *out_eip / *out_esp (the core's reset EIP/ESP); -1 if the
// image fails to load.
int ven_quake_init(volatile uint8_t* ddr, uint32_t mask, const char* image_json,
                   const char* video_path, uint32_t brk_base,
                   uint32_t* out_eip, uint32_t* out_esp);

// Emulate one int-0x80 (i386 ABI: nr=eax, args=ebx,ecx,edx,esi,edi,ebp). The
// kernel memory effects are written DIRECTLY into the carveout (no write-back
// step). `cycles` drives the synthetic monotonic clock for the time syscalls.
// Fills *res.
void ven_quake_service(uint32_t nr, uint32_t ebx, uint32_t ecx, uint32_t edx,
                       uint32_t esi, uint32_t edi, uint32_t ebp,
                       uint64_t cycles, struct ven_sys_result* res);

// Drain newly-captured P5Q1 framebuffer bytes (since the last drain) into `buf`
// (up to `max`). Returns the count copied. Lets the caller stream the frame
// stream to a file / framebuffer live.
uint32_t ven_quake_video_drain(uint8_t* buf, uint32_t max);

// Total P5Q1 bytes captured so far (final size report) and syscalls serviced.
uint64_t ven_quake_video_total(void);
uint64_t ven_quake_syscalls(void);

#ifdef __cplusplus
}
#endif
#endif  // VEN_QUAKE_H
