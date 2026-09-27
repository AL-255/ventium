// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// verif/tb/xover.cpp — task #102 state-crossover harness (RTL side).
//
// Reads and writes the Ventium core's internal architectural registers through
// the Verilated model hierarchy. ALL access is via the `--public-flat-rw` flat
// signal table on top->rootp; NO RTL ports/annotations were added (the committed
// core.sv / ventium_top.sv stay byte-identical). Compiled only under -DVEN_XOVER.
//
// Hierarchy paths (verified against obj_dir_l1axi_kvdosq_xover/*___024root.h):
//   ventium_top__DOT__u_core__DOT__eip / eflags / creg0..4
//   ventium_top__DOT__u_core__DOT__seg_sel/base/limit/attr  (VlUnpacked<...,6>)
//   ventium_top__DOT__u_core__DOT__gdt_base/limit idt_base/limit
//                                  ldt_base/limit tr_base/limit/sel/attr
//   ventium_top__DOT__u_core__DOT__u_regfile__DOT__gpr      (VlUnpacked<IData,8>)
//   ventium_top__DOT__u_core__DOT__u_fpu_state__DOT__fpr    (VlUnpacked<VlWide<3>,8>)
//   ventium_top__DOT__u_core__DOT__u_fpu_state__DOT__ftop/fctrl/fstat/fptag
#ifdef VEN_XOVER

#include "xover.h"
#include "Vventium_top.h"
#include "Vventium_top___024root.h"
#include "memmodel.h"

#include <cstddef>
#include <cstdio>
#include <cstring>

namespace ventium {

// Shorthand for the flat root struct (the --public-flat-rw signal table).
#define RP (top->rootp)
#define CORE(sig)  RP->ventium_top__DOT__u_core__DOT__##sig
#define RF(sig)    RP->ventium_top__DOT__u_core__DOT__u_regfile__DOT__##sig
#define FP(sig)    RP->ventium_top__DOT__u_core__DOT__u_fpu_state__DOT__##sig
#define ITLB(sig)  RP->ventium_top__DOT__u_core__DOT__u_itlb__DOT__##sig
#define DTLB(sig)  RP->ventium_top__DOT__u_core__DOT__u_dtlb__DOT__##sig

void xover_extract(Vventium_top* top, XoverArch& a) {
    std::memset(&a, 0, sizeof(a));
    std::memcpy(a.magic, "VENXOVR", 8);   // includes the trailing NUL
    a.version = XOVER_VERSION;

    // GPRs — read the registered file (PRE-edge architectural state).
    for (int i = 0; i < 8; ++i) a.gpr[i] = RF(gpr)[i];

    a.eip    = CORE(eip);
    a.eflags = CORE(eflags);

    // Segments (cs ss ds es fs gs).
    for (int i = 0; i < 6; ++i) {
        a.seg_sel  [i] = CORE(seg_sel) [i];
        a.seg_base [i] = CORE(seg_base)[i];
        a.seg_limit[i] = CORE(seg_limit)[i];
        a.seg_attr [i] = CORE(seg_attr)[i];
    }

    a.cr0 = CORE(creg0);
    a.cr2 = CORE(creg2);
    a.cr3 = CORE(creg3);
    a.cr4 = CORE(creg4);

    a.gdt_base = CORE(gdt_base);  a.gdt_limit = CORE(gdt_limit);
    a.idt_base = CORE(idt_base);  a.idt_limit = CORE(idt_limit);
    a.ldt_base = CORE(ldt_base);  a.ldt_limit = CORE(ldt_limit);  a.ldt_sel = 0; // not stored in RTL
    a.tr_base  = CORE(tr_base);   a.tr_limit  = CORE(tr_limit);   a.tr_sel  = CORE(tr_sel);
    a.tr_attr  = (uint8_t)CORE(tr_attr);   a.ldt_attr = 0;  // RTL has no ldt_attr reg

    // Derived mode flops (the RTL loads cs_d/cpl_r from the CS descriptor during a
    // far jump; they are NOT reconstructable from the injected eflags/cr0/seg
    // fields). cs_d gates def16 -> q_cnt16 -> the 16/32-bit address size.
    a.cs_d = (uint8_t)CORE(cs_d);
    a.cpl  = (uint8_t)CORE(cpl_r);

    // x87 control + physical stack.
    a.fctrl = CORE(fctrl);
    a.fstat = CORE(fstat);
    a.ftag  = (uint8_t)FP(fptag);
    a.ftop  = (uint8_t)FP(ftop);
    for (int i = 0; i < 8; ++i) {
        // fpr[i] is a VlWide<3> (80 bits across 3×32-bit words, LSW first).
        uint32_t w0 = FP(fpr)[i].at(0);
        uint32_t w1 = FP(fpr)[i].at(1);
        uint32_t w2 = FP(fpr)[i].at(2);
        a.fpr_lo[i] = ((uint64_t)w1 << 32) | w0;   // mantissa [63:0]
        a.fpr_hi[i] = (uint16_t)(w2 & 0xFFFF);     // sign|exp  [79:64]
    }
}

uint32_t xover_read_cr2(Vventium_top* top) {
    return (uint32_t)CORE(creg2);
}

uint8_t xover_read_fault_state(Vventium_top* top, XoverFaultState& fs) {
    fs.walk_lin      = (uint32_t)CORE(walk_lin);
    fs.walk_is_write = (uint8_t)CORE(walk_is_write);
    fs.walk_step     = (uint8_t)CORE(walk_step);
#ifdef VEN_XOVER_FE_PIPE
    fs.fe_dtlb_hit   = (uint8_t)CORE(fe_dtlb_hit);
    fs.fe_dtlb_v     = (uint8_t)CORE(fe_dtlb_v);
    fs.fe_dtlb_dirty = (uint8_t)CORE(fe_dtlb_dirty);
    fs.fe_dtlb_page  = (uint32_t)CORE(fe_dtlb_page);
    fs.fe_dtlb_phys  = (uint32_t)CORE(fe_dtlb_phys);
#else
    // The diagnostic structure is stable across profile builds.  These flops
    // are optimized out when the RTL has no FE_PIPE, so report their inert
    // state rather than trying to access a hierarchy member that does not exist.
    fs.fe_dtlb_hit = 0;
    fs.fe_dtlb_v = 0;
    fs.fe_dtlb_dirty = 0;
    fs.fe_dtlb_page = 0;
    fs.fe_dtlb_phys = 0;
#endif
    fs.dtlb_lk_hit   = (uint8_t)CORE(dtlb_lk_hit);
    fs.dtlb_lk_dirty = (uint8_t)CORE(dtlb_lk_dirty);
    fs.dtlb_lk_phys  = (uint32_t)CORE(dtlb_lk_phys);
    fs.xlate_miss    = (uint8_t)CORE(xlate_miss);
    fs.cur_lin       = (uint32_t)CORE(cur_lin);
    fs.pf_errcode    = (uint32_t)CORE(pf_errcode);
    return (uint8_t)CORE(walk_pf);
}

void xover_inject(Vventium_top* top, const XoverArch& a) {
    for (int i = 0; i < 8; ++i) RF(gpr)[i] = a.gpr[i];

    CORE(eip)    = a.eip;
    CORE(eflags) = a.eflags;

    for (int i = 0; i < 6; ++i) {
        CORE(seg_sel) [i] = a.seg_sel  [i];
        CORE(seg_base)[i] = a.seg_base [i];
        CORE(seg_limit)[i]= a.seg_limit[i];
        CORE(seg_attr)[i] = a.seg_attr [i];
    }

    CORE(creg0) = a.cr0;
    CORE(creg2) = a.cr2;
    CORE(creg3) = a.cr3;
    CORE(creg4) = a.cr4;

    CORE(gdt_base) = a.gdt_base;  CORE(gdt_limit) = a.gdt_limit;
    CORE(idt_base) = a.idt_base;  CORE(idt_limit) = a.idt_limit;
    CORE(ldt_base) = a.ldt_base;  CORE(ldt_limit) = a.ldt_limit;
    CORE(tr_base)  = a.tr_base;   CORE(tr_limit)  = a.tr_limit;  CORE(tr_sel) = a.tr_sel;
    CORE(tr_attr)  = a.tr_attr;

    // Derived mode flops: restore CS.D (cs_d) and CPL (cpl_r). Without cs_d the
    // injected 32-bit code (cs_d=0 after reset) runs with def16=1 -> 16-bit
    // default address size -> string/[ESI]/[EDI] pointers truncated to 16 bits
    // (e.g. ESI 0x03EA04BC -> 0x04BC) -> a spurious #PF. (No separate SS B-bit
    // flop exists: the stack 16-bit mask `stk16` is gated on real_mode only, which
    // is reconstructed from creg0[0] — so PM keeps 32-bit ESP automatically.)
    CORE(cs_d)  = a.cs_d & 1;
    CORE(cpl_r) = a.cpl & 3;

    // x87: write both the spine mirrors (fctrl/fstat live in the core scope) and
    // the fpu_state physical regs/ftop/tag (the registered source of truth).
    CORE(fctrl) = a.fctrl;
    CORE(fstat) = a.fstat;
    FP(fctrl)   = a.fctrl;
    FP(fstat)   = a.fstat;
    FP(fptag)   = a.ftag;
    FP(ftop)    = a.ftop & 7;
    for (int i = 0; i < 8; ++i) {
        uint32_t w0 = (uint32_t)(a.fpr_lo[i] & 0xFFFFFFFFu);
        uint32_t w1 = (uint32_t)(a.fpr_lo[i] >> 32);
        uint32_t w2 = (uint32_t)a.fpr_hi[i];
        FP(fpr)[i].at(0) = w0;
        FP(fpr)[i].at(1) = w1;
        FP(fpr)[i].at(2) = w2;
    }
    // Invalidate BOTH split TLBs. The injected cr3 (a.cr3) is written directly
    // (not via a MOV CR3 instruction), so the hardware CR3-flush pulse never
    // fires and the I/D TLBs retain stale entries from the reset/boot state
    // (paging-off, cr3=0). The first post-crossover data access would otherwise
    // hit a stale D-TLB entry -> wrong phys -> spurious #PF. Clearing the `val`
    // bits forces a fresh page walk over the injected page tables (exactly what
    // a real MOV CR3 does: IA-32 §4.10 invalidates non-global TLB entries).
    //
    // Do NOT encode the historical 16-entry geometry here.  The default D-TLB
    // is 16 direct-mapped entries, while the optional associative experiment
    // exposes 32 or 64 flat entries at the same hierarchy path.  Derive each
    // capacity from the generated Verilator array so a crossover cannot leave
    // an upper associative way live across the direct CR3 injection.
    constexpr std::size_t itlb_entries = sizeof(ITLB(tlb_val)) / sizeof(ITLB(tlb_val)[0]);
    constexpr std::size_t dtlb_entries = sizeof(DTLB(tlb_val)) / sizeof(DTLB(tlb_val)[0]);
    for (std::size_t i = 0; i < itlb_entries; ++i) ITLB(tlb_val)[i] = 0;
    for (std::size_t i = 0; i < dtlb_entries; ++i) DTLB(tlb_val)[i] = 0;

    // FE_PIPE may satisfy a translation from its registered micro-TLB before
    // consulting the raw arrays above.  Its cache is not architectural state
    // and is absent from XoverArch, so it must be invalidated with the raw
    // arrays; otherwise a restored same-VA entry can retain the old CR3's PFN.
    // In a non-FE_PIPE build Verilator optimizes these hierarchy members away;
    // the Makefile defines VEN_XOVER_FE_PIPE only when its RTL counterpart is
    // enabled.
#ifdef VEN_XOVER_FE_PIPE
    CORE(fe_itlb_v) = 0;
    CORE(fe_dtlb_v) = 0;
#endif

    // Force the FSM to S_FETCH so the very next step re-fetches the instruction
    // stream from the injected cs:eip (the pipeline is otherwise stale).
    CORE(state) = 1 /*S_FETCH*/;
}

bool xover_save(const std::string& prefix, const XoverArch& a, const MemModel& mem) {
    std::string ap = prefix + ".arch";
    FILE* af = std::fopen(ap.c_str(), "wb");
    if (!af) { std::fprintf(stderr, "xover: cannot open %s for write\n", ap.c_str()); return false; }
    std::fwrite(&a, sizeof(a), 1, af);
    std::fclose(af);

    std::string mp = prefix + ".mem";
    FILE* mf = std::fopen(mp.c_str(), "wb");
    if (!mf) { std::fprintf(stderr, "xover: cannot open %s for write\n", mp.c_str()); return false; }
    mem.snapshot(mf);
    std::fclose(mf);
    std::fprintf(stderr, "xover: SAVED arch -> %s + mem -> %s\n", ap.c_str(), mp.c_str());
    return true;
}

bool xover_load(const std::string& prefix, XoverArch& a, MemModel& mem) {
    std::string ap = prefix + ".arch";
    FILE* af = std::fopen(ap.c_str(), "rb");
    if (!af) { std::fprintf(stderr, "xover: cannot open %s for read\n", ap.c_str()); return false; }
    size_t n = std::fread(&a, 1, sizeof(a), af);
    std::fclose(af);
    if (n != sizeof(a)) {
        std::fprintf(stderr, "xover: %s short read (%zu != %zu)\n", ap.c_str(), n, sizeof(a));
        return false;
    }
    if (std::memcmp(a.magic, "VENXOVR", 8) != 0 || a.version != XOVER_VERSION) {
        std::fprintf(stderr, "xover: %s bad magic/version (got v%u)\n", ap.c_str(), a.version);
        return false;
    }

    std::string mp = prefix + ".mem";
    FILE* mf = std::fopen(mp.c_str(), "rb");
    if (!mf) { std::fprintf(stderr, "xover: cannot open %s for read\n", mp.c_str()); return false; }
    mem.restore(mf);
    std::fclose(mf);
    std::fprintf(stderr, "xover: LOADED arch <- %s + mem <- %s\n", ap.c_str(), mp.c_str());
    return true;
}

void xover_dump_summary(const char* tag, const XoverArch& a) {
    std::fprintf(stderr,
        "xover[%s]: cs:eip=%04x:%08x eflags=%08x cr0=%08x cr3=%08x\n"
        "          eax=%08x ecx=%08x edx=%08x ebx=%08x esp=%08x ebp=%08x esi=%08x edi=%08x\n"
        "          ds=%04x es=%04x fs=%04x gs=%04x ss=%04x  gdt=%08x/%04x ldt=%08x/%04x tr=%04x ftop=%u\n",
        tag, a.seg_sel[0], a.eip, a.eflags, a.cr0, a.cr3,
        a.gpr[0], a.gpr[1], a.gpr[2], a.gpr[3], a.gpr[4], a.gpr[5], a.gpr[6], a.gpr[7],
        a.seg_sel[2], a.seg_sel[3], a.seg_sel[4], a.seg_sel[5], a.seg_sel[1],
        a.gdt_base, a.gdt_limit, a.ldt_base, a.ldt_limit, a.tr_sel, a.ftop);
}

#undef RP
#undef CORE
#undef RF
#undef FP
#undef ITLB
#undef DTLB

}  // namespace ventium

#endif  // VEN_XOVER
