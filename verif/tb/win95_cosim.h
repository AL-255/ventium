// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/tb/win95_cosim.h
//
// M7.3b Win95 system co-sim CONSUMER (docs/m7-lockstep-spec.md M7.3). The
// counterpart of the M7.3a producer: qemu-system-i386 (under rr=replay) was the
// golden reference AND the environment; the Ventium RTL is the CHECKED CPU.
//
// Two read-only loaders the TB uses in --win95-image / --lockstep mode, parsing
// the producer's two artifacts (the M7.3a contract):
//
//   1. Win95Image — the INITIAL PHYSICAL-MEMORY image sidecar JSON (one line):
//        {"regs":{...},"seg":{...},"seg_base":{...},
//         "regions":[ {"paddr":"0x..","hex":"<bytes>"} , ... ], "meta":{}}
//      The TB maps every PHYS region verbatim into the bus memory at its paddr
//      (the loader plays QEMU's reset-time physical-memory image). The core then
//      cold-resets at F000:FFF0 (boot_mode=system) — its reset arch state already
//      matches golden record 0 (cs=0xf000, cr0=0x60000010, eflags=0x2), with the
//      EDX P5 `-cpu pentium` stepping signature 0x543 selected by cosim_en in the
//      RTL reset. The image regs are loaded only for a cross-check (the core's
//      own reset is authoritative — we never inject CPU-computed register state).
//
//   2. DevInReplay — the GOLDEN .vtrace's dev_in[] read VALUES, in retire order.
//      For each record that carries a `dev_in` field we keep one DevIn per entry
//      {n, port, val, size, region}. These are the ONLY environment inputs the
//      RTL cannot compute (a device returned them); the TB returns each, IN ORDER,
//      for the matching IN the core issues on the io_* bus (cross-checking the
//      port + size). It NEVER injects CPU-computed registers/flags/eip — only the
//      device-read value (the integrity crux the review audits).
//
// The golden's `dma_wr` entries in this prefix are ALL CPU-driven OUT writes to
// I/O ports (0x70/0x92/0x402/0xCF8/0xCFC/0x510/0x518) plus one platform reset
// apic-msi MMIO write — NOT DMA-into-RAM. So there are NO memory writes to inject
// in the bounded prefix (verified: every dma_wr addr is an I/O port, none is a
// RAM address). The RTL EXECUTES those OUTs itself; the TB only consumes them
// (and uses them as an optional cross-check). The 300k prefix has 0 interrupts
// (intr injection deferrable), asserted at load.
//
// The parser is intentionally minimal — it understands ONLY the fixed shapes the
// producer emits (paddr-keyed hex regions; decimal dev_in {addr,val,size,region}),
// so it stays dependency-free, like quake_image.cpp.
#ifndef VENTIUM_WIN95_COSIM_H
#define VENTIUM_WIN95_COSIM_H

#include <cstdint>
#include <string>
#include <vector>

#include "memmodel.h"

namespace ventium {

// The initial physical-memory image: regs/segs (cross-check) + the phys regions,
// already loaded into bus memory at their paddrs.
struct Win95Image {
    // initial architectural registers (from "regs") — informational cross-check.
    uint32_t eip = 0, esp = 0, eflags = 0;
    uint32_t eax = 0, ecx = 0, edx = 0, ebx = 0, ebp = 0, esi = 0, edi = 0;
    uint16_t cs = 0, ss = 0, ds = 0, es = 0, fs = 0, gs = 0;
    long     n_regions = 0;
    long long total_bytes = 0;
    bool     ok = false;
};

// One replayable device-read value (one dev_in[] entry of one golden record).
struct DevIn {
    uint64_t n      = 0;    // golden record `n` that consumed this read
    uint32_t port   = 0;    // I/O port (dev_in.addr)
    uint64_t val    = 0;    // the device-returned value (dev_in.val; up to 64-bit)
    uint32_t size   = 1;    // access width in bytes (1/2/4)
    std::string region;     // dev_in.region (rtc / port92 / pci-conf-data / ...)
};

// Parse + load the initial image JSON into `mem` (phys regions at their paddrs).
// Returns the image (ok=true) or ok=false on a parse/IO failure.
Win95Image load_win95_image(const std::string& path, MemModel& mem);

// Parse the golden .vtrace, collecting every dev_in[] read VALUE in retire order
// (flattened: one DevIn per dev_in entry). Also asserts the prefix carries no
// `intr` records (sets *had_intr if any appear, so the caller can report). The
// vector is empty on a parse/IO failure (caller treats as "nothing to replay").
std::vector<DevIn> load_devin_replay(const std::string& golden_path,
                                     bool* had_intr = nullptr);

}  // namespace ventium

#endif  // VENTIUM_WIN95_COSIM_H
