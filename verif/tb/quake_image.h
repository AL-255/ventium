// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/tb/quake_image.h
//
// M7.1 Quake user-mode lock-step consumer (docs/m7-lockstep-spec.md).
//
// Two small read-only loaders the TB uses when run in --quake-image / --lockstep
// mode, parsing the PRODUCER's two artifacts (the M7.0/M7.1 contract):
//
//   1. QuakeImage  — the INITIAL PROCESS IMAGE sidecar JSON (one line):
//        {"regs":{...},"seg":{...},"seg_base":{...},
//         "regions":[ {"vaddr","hex"} | {"vaddr","len","zero":true} ], "meta":{}}
//      The TB maps every region verbatim into the bus memory, then seeds the
//      core's reset regs (eip=entry, esp, eflags) + the flat user selectors.
//      (gs_base from seg_base is DELIBERATELY ignored — the producer's contract
//      says the linux-user gdbstub mis-names the segment-base slots, so the true
//      %gs TLS base is taken from the set_thread_area sys_call.gs_base instead.)
//
//   2. SyscallReplay — the GOLDEN .vtrace's int-0x80 `sys_call` effects, in
//      retire order. For each record that carries a `sys_call` field we keep
//      {n, ret, gs_base?, writes[], resume_eip}. resume_eip is the pc of the
//      golden's NEXT record (n+1): QEMU's -one-insn-per-tb single-step over the
//      cd80 site folds the instruction immediately after it, so the post-syscall
//      resume EIP comes from the golden, not from cd80+2. The TB replays these in
//      order at each core syscall_active pulse: apply the kernel memory writes to
//      its bus memory, then drive ret/resume_eip/gs back into the core.
//
// These files are produced by gen_trace.py --syscall-proxy (verif/qemu-trace).
// The parser is intentionally minimal — it understands ONLY the fixed shapes the
// producer emits (no general JSON), so it stays dependency-free.
#ifndef VENTIUM_QUAKE_IMAGE_H
#define VENTIUM_QUAKE_IMAGE_H

#include <cstdint>
#include <string>
#include <vector>

#include "memmodel.h"

namespace ventium {

// The initial process image: regs/segs + the memory regions, already loaded.
struct QuakeImage {
    // initial architectural registers (from "regs")
    uint32_t eip = 0, esp = 0, eflags = 0;
    uint32_t eax = 0, ecx = 0, edx = 0, ebx = 0, ebp = 0, esi = 0, edi = 0;
    // initial selectors (from "seg")
    uint16_t cs = 0, ss = 0, ds = 0, es = 0, fs = 0, gs = 0;
    bool     ok = false;
};

// One replayable int-0x80 effect.
struct SyscallEffect {
    uint64_t n          = 0;        // the golden record `n` of the int-0x80
    uint32_t ret        = 0;        // sys_call.ret -> eax
    uint32_t resume_eip = 0;        // golden NEXT-record pc (post-syscall resume)
    bool     has_resume = false;    // false only if the int-0x80 is the last record
    bool     apply_gs   = false;    // sys_call carried a gs_base
    uint32_t gs_base    = 0;        // the TLS base, if apply_gs
    // memory writes: explicit-byte regions; a zero region is {addr,len,zero}.
    struct Write { uint32_t addr; std::vector<uint8_t> bytes; uint32_t zlen; bool zero; };
    std::vector<Write> writes;
};

// Parse + load the initial image JSON into `mem`. Returns the image (ok=true)
// or ok=false on a parse/IO failure. Zero regions are NOT materialised (MemModel
// reads unmapped as 0), keeping the 7 MB anon zone sparse.
QuakeImage load_quake_image(const std::string& path, MemModel& mem);

// Parse the golden .vtrace, collecting every int-0x80 `sys_call` effect in
// retire order (with each one's resume_eip resolved from the following record's
// pc). Returns the effects; the vector is empty on a parse/IO failure (which the
// caller treats as "no syscalls to replay").
std::vector<SyscallEffect> load_syscall_replay(const std::string& golden_path);

}  // namespace ventium

#endif  // VENTIUM_QUAKE_IMAGE_H
