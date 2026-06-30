// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// verif/tb/xover.h — task #102 state-crossover harness.
//
// Serializes the full x86 architectural state of the Ventium core at a clean
// instruction boundary, and re-injects it. The on-disk schema (XoverArch) is the
// SHARED contract between this RTL-side extractor and the qemu-oracle patch
// (ventium-refs/.../VEN_XOVER_{LOAD,SAVE}). Same struct, same byte layout, so a
// `.arch` file written by either side loads on the other.
//
// This whole file is compiled ONLY when -DVEN_XOVER is set (the
// l1axi_kv_dos_q_xover Makefile target, built with --public-flat-rw). The default
// tb and every committed gate never see it. NO RTL is touched — the extractor
// reaches the core's internal registers purely through the Verilated model
// hierarchy (top->rootp->ventium_top__DOT__u_core__DOT__...), enabled by the
// --public-flat-rw build flag alone.
#ifndef VENTIUM_XOVER_H
#define VENTIUM_XOVER_H
#ifdef VEN_XOVER

#include <cstdint>
#include <string>

class Vventium_top;          // forward decl (full def via Vventium_top.h in xover.cpp)
namespace ventium { class MemModel; }

namespace ventium {

// ---- the crossover arch-state schema (on-disk, fixed layout) ----------------
// Packed, fixed-width, little-endian fields. Versioned + magic'd so a mismatched
// file is rejected loudly rather than silently mis-loaded. KEEP IN SYNC with the
// qemu-oracle patch's struct of the same name.
#pragma pack(push, 1)
struct XoverArch {
    char     magic[8];        // "VENXOVR\0"
    uint32_t version;         // XOVER_VERSION
    uint32_t _pad0;

    uint32_t gpr[8];          // eax ecx edx ebx esp ebp esi edi
    uint32_t eip;
    uint32_t eflags;

    // 6 segments: cs ss ds es fs gs (Ventium order; qemu maps to its R_xS).
    uint16_t seg_sel  [6];
    uint16_t _pad1    [6];
    uint32_t seg_base [6];
    uint32_t seg_limit[6];    // hidden (byte-granular) limit
    uint8_t  seg_attr [6];    // descriptor access byte: P|DPL|S|type
    uint8_t  _pad2    [2];

    uint32_t cr0, cr2, cr3, cr4;

    uint32_t gdt_base;  uint16_t gdt_limit;  uint16_t _pad3;
    uint32_t idt_base;  uint16_t idt_limit;  uint16_t _pad4;
    uint32_t ldt_base;  uint16_t ldt_limit;  uint16_t ldt_sel; // ldt_sel not stored in RTL -> 0
    uint32_t tr_base;   uint16_t tr_limit;   uint16_t tr_sel;
    uint8_t  tr_attr;   uint8_t  ldt_attr;   uint16_t _pad_tr;  // descriptor access bytes

    // x87: control/status/tag + TOP + the 8 *physical* 80-bit registers fpr[0..7]
    // (fpr[i], NOT TOP-relative ST(i)). Each ST is hi:lo = (sign|exp)<<64 | mant.
    uint16_t fctrl, fstat;
    uint8_t  ftag;            // 8-bit raw tag word (bit i = tag for fpr[i])
    uint8_t  ftop;            // 3-bit TOP
    uint8_t  _pad5[2];
    uint64_t fpr_lo[8];       // mantissa [63:0]
    uint16_t fpr_hi[8];       // sign|exp [79:64]

    // Derived MODE flops that the RTL loads from the CS descriptor during a far
    // jump (core_seg_ljmp.svh) but that are NOT reconstructable from eflags/cr0/
    // the injected seg fields — so the crossover MUST carry them explicitly or the
    // injected target runs with the reset defaults (cs_d=0 => 16-bit default addr
    // size => string pointers truncated to 16 bits => spurious #PF). See the
    // q_cnt16/def16 chain in core.sv (def16 = sys_mode && !cs_d).
    uint8_t  cs_d;            // CS descriptor D/B bit (1 = 32-bit default op/addr)
    uint8_t  cpl;             // current privilege level (CS.RPL after the far jmp)
    uint16_t _pad6[3];        // (was [4]; 2 bytes repurposed — size unchanged)
};
#pragma pack(pop)

static constexpr uint32_t XOVER_VERSION = 2;

// Read the core's internal arch state out of the Verilated hierarchy into `a`.
// Caller must ensure the FSM is at a clean instruction boundary (S_DECODE, no
// in-flight uop / no pending NBA on the registered files).
void xover_extract(Vventium_top* top, XoverArch& a);

// Write the arch state in `a` INTO the core's internal registers (gpr/eip/eflags/
// seg_*/cr*/gdt/idt/ldt/tr/x87). Called at a clean boundary; the caller is
// responsible for L1 cache flush + next-fetch redirect afterwards.
void xover_inject(Vventium_top* top, const XoverArch& a);

// Read the core's CR2 (the page-fault linear address) directly out of the flat
// hierarchy — for fault diagnostics where the faulting insn never retires (so the
// XoverArch snapshot can't catch it).
uint32_t xover_read_cr2(Vventium_top* top);

// Cycle-precise #PF forensic snapshot. `walk_pf` is the page-walk's fault-raise
// flag (set the same edge CR2<=walk_lin + start_fault(14) fire, BEFORE any handler
// runs). When it's high this reads walk_lin (the EXACT faulting linear addr) plus
// the FE_PIPE/dtlb micro-state so an RTL-addressing-bug (spurious #PF on a mapped
// page) can be told apart from a genuine not-present access. Returns walk_pf.
struct XoverFaultState {
    uint32_t walk_lin;       // faulting linear address (the EA the walk used)
    uint8_t  walk_is_write;
    uint8_t  walk_step;
    uint8_t  fe_dtlb_hit, fe_dtlb_v, fe_dtlb_dirty;
    uint32_t fe_dtlb_page, fe_dtlb_phys;
    uint8_t  dtlb_lk_hit, dtlb_lk_dirty;
    uint32_t dtlb_lk_phys;
    uint8_t  xlate_miss;
    uint32_t cur_lin;
    uint32_t pf_errcode;
};
uint8_t xover_read_fault_state(Vventium_top* top, XoverFaultState& fs);

// Serialize: write <prefix>.arch (the XoverArch blob) + <prefix>.mem (full
// MemModel snapshot via mem.snapshot()). Returns true on success.
bool xover_save(const std::string& prefix, const XoverArch& a, const MemModel& mem);

// Deserialize: read <prefix>.arch into `a` (validates magic+version) + <prefix>.mem
// into `mem` (mem.restore()). Returns true on success.
bool xover_load(const std::string& prefix, XoverArch& a, MemModel& mem);

// Human-readable one-line summary (cs:eip, key regs) for logging.
void xover_dump_summary(const char* tag, const XoverArch& a);

}  // namespace ventium

#endif  // VEN_XOVER
#endif  // VENTIUM_XOVER_H
