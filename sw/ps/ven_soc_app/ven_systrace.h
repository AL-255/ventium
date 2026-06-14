// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/ven_systrace.h — PS-side observability for the F4 int-0x80
// Quake proxy. A self-contained bookkeeping layer over data the --quake service
// loop already has ({nr, args, eax, cyc}, the video/syscall counters). It owns a
// decoded last-N syscall RING, a per-NR HISTOGRAM, a no-progress WATCHDOG, a
// same-syscall LIVELOCK detector, a frame/first-frame HEARTBEAT, a live stdout
// TEE, and a non-destructive SIGUSR1 SNAPSHOT. All recording is gated off by
// default (a single early-return) so production runs pay nothing. It reuses, and
// does NOT duplicate, the existing dbg_dump_core() / VEN_DBG / vga_textdump infra
// (the caller pairs systrace_dump() with dbg_dump_core() at the failure points).
//
// Env vars (read once at systrace_init):
//   VEN_SYS_RING=1        enable the syscall ring + histogram (dumped on abnormal exit)
//   SYS_TIMEOUT_MS=<ms>   no-progress watchdog (default 2000 when ring/VEN_DBG set; 0=off)
//   SYS_LIVELOCK_N=<n>    same-syscall-repeat ADVISORY threshold (default 0=off; opt-in only).
//                         When set, it WARNS once (never aborts) — a healthy guest can
//                         legitimately repeat a syscall many times.
//   SYS_COMMIT_VERIFY=1   re-read SYS_PEND after each commit (catches a lost handshake)
//   VEN_QUAKE_LIVE_TTY=1  tee the guest's fd 1/2 output to stderr live
//   SYS_VIDEO_STALL_K=<n> warn if video bytes flat for N syscalls while syscalls advance
#ifndef VEN_SYSTRACE_H
#define VEN_SYSTRACE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SYSTRACE_LIVELOCK  0x1   // systrace_record(): the same syscall is repeating

// Read env once. Safe to call with no proxy active (everything stays disabled).
void systrace_init(void);

// Record ONE serviced syscall, AFTER ven_quake_service() returns (so eax is known).
// args[] = {ebx,ecx,edx,esi,edi,ebp}. Returns a flag bitmask (SYSTRACE_LIVELOCK).
// No-op (immediate return) when VEN_SYS_RING is unset.
int  systrace_record(uint32_t nr, const uint32_t args[6], uint32_t eax,
                     int unsupported, uint64_t syscall_index, uint64_t cyc);

// No-progress watchdog. Call once per main-loop iteration with the live syscall +
// retire counters and the SYS_PEND bit; returns 1 if nothing has advanced for
// SYS_TIMEOUT_MS (a wedged handshake / stuck core), else 0. Cheap; the caller
// should only read the retire counter when systrace_watchdog_enabled() is true.
int  systrace_watchdog_enabled(void);
int  systrace_watchdog(uint64_t syscalls, uint64_t retire, int sys_pend);

// Post-commit verify enabled? (the caller re-reads SYS_PEND after R_SYS_CTRL).
int  systrace_commit_verify_enabled(void);

// 250ms heartbeat: returns a static suffix string (" frames=.. Δ=.. sys=.. rate=..")
// to append to the VEN_DBG line, and internally latches/announces the first frame
// + warns on a renderer stall. video_bytes/syscalls are the live counters.
const char* systrace_heartbeat(uint64_t video_bytes, uint64_t syscalls);

// Live stdout tee: print any new guest fd 1/2 bytes (banner / Sys_Error panic) to
// stderr. No-op unless VEN_QUAKE_LIVE_TTY=1. Call after each syscall.
void systrace_tee_stdout(void);

// Dump the decoded ring (newest first) + the per-NR histogram to stderr, labelled
// `reason`. Call at every abnormal exit (unsupported / exit / hung / stall / term),
// paired with dbg_dump_core() by the caller. No-op when the ring is disabled.
void systrace_dump(const char* reason);

// Non-destructive snapshot (SIGUSR1 body): print syscalls/video/first-frame +
// the ring head + the guest stdout tail, WITHOUT exiting. Best-effort async use.
void systrace_snapshot(void);

#ifdef __cplusplus
}
#endif
#endif  // VEN_SYSTRACE_H
