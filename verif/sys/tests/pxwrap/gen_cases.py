#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# pxwrap / pxwrapm case-table generator.
#
# Implements the cross-privilege frame SLOT PLAN (rtl/core/core.sv
# frm_slot_off: slot k sits at offset esp-(k+1)*unit, wrapped by the new
# stack's B bit) and QEMU 8.2.2's push order (seg_helper.c
# do_interrupt_protected / helper_lcall_protected: PUSHL/PUSHW decrement sp
# first, so slot 0 is the FIRST push at the HIGHEST address, and every push
# stores at SS.base + (sp & sp_mask)).  For each generated case the script
# enumerates the distinct pages the frame touches in first-touch (push)
# order; one test run is emitted per page denial.  It also computes the
# expected #PF CR2 for every denial: QEMU faults on the FIRST push that has
# a byte on the denied page, reporting the push's start address -- or the
# page base when that push straddles into the denied page from a present one
# (cputlb.c mmu_lookup: page[1].addr = (addr+size-1) & TARGET_PAGE_MASK).
# The RTL's S_INT_PROBE walks the same plan in the same order and reports
# the same address, which is what makes the deny flow differential.
#
# Usage: python3 gen_cases.py           (writes both .inc files + report)
#        python3 gen_cases.py --report  (report only, to stdout)

import sys, os

KIND_INT, KIND_GP, KIND_CG, KIND_V86INT, KIND_V86GP = 1, 2, 3, 4, 5
FL_ERR, FL_G16, FL_TRAP = 1, 2, 4

USER_ESP_INT = 0xF000   # CPL3 ESP at the int/gp trigger
USER_ESP_CG16 = 0xEFC0  # CPL3 ESP at the 16-bit-gate lcall (31 word params)
USER_ESP_CG32 = 0xEF80  # CPL3 ESP at the 32-bit-gate lcall (31 dword params)


def slots_of(esp0, nslots, unit, b32, ss_base):
    """[(k, off, la)] in push order; la = SS.base + frm_slot_off(esp0,k)."""
    mask = 0xFFFFFFFF if b32 else 0xFFFF
    out = []
    for k in range(nslots):
        off = (esp0 - (k + 1) * unit) & mask
        out.append((k, off, (ss_base + off) & 0xFFFFFFFF))
    return out


def slot_pages(la, unit):
    """Pages a slot touches, low page first."""
    p0 = la & ~0xFFF
    p1 = ((la + unit - 1) & 0xFFFFFFFF) & ~0xFFF
    return [p0] if p0 == p1 else [p0, p1]


def pages_in_order(slots, unit):
    """Distinct frame pages in first-touch (push) order."""
    pages = []
    for _, _, la in slots:
        for p in slot_pages(la, unit):
            if p not in pages:
                pages.append(p)
    return pages


def fault_slot(slots, unit, deny):
    """First slot (push order) with a byte on page `deny`; (k, cr2) or None.

    CR2 = the slot's start address when the slot's first byte is already on
    the denied page; the page base when the slot straddles into it."""
    for k, _, la in slots:
        ps = slot_pages(la, unit)
        if deny in ps:
            return k, (la if ps[0] == deny else deny)
    return None


def written_mask(k_fault):
    """Slots QEMU writes before the fault: complete slots 0..k_fault-1
    (a cross-page store is never partially written)."""
    return (1 << k_fault) - 1


class Case:
    def __init__(self, kind, b32, nslots, flags, esp0, ss_base, deny):
        self.kind, self.b32, self.nslots = kind, b32, nslots
        self.flags, self.esp0, self.ss_base, self.deny = flags, esp0, ss_base, deny
        self.unit = 2 if (flags & FL_G16) else 4
        s = slots_of(esp0, nslots, self.unit, b32, ss_base)
        self.slots = s
        if deny is not None:
            fk = fault_slot(s, self.unit, deny)
            assert fk is not None, f"deny page {deny:#x} not touched"
            self.k_fault, self.cr2 = fk
        else:
            self.k_fault, self.cr2 = None, None

    def inc(self):
        c = (f"  /* k{self.kind} b32={self.b32} n={self.nslots} f={self.flags:#x} "
             f"esp0={self.esp0:#x} base={self.ss_base:#x} deny={self.deny if self.deny is not None else 0:#010x} "
             f"kflt={self.k_fault} cr2={self.cr2 and hex(self.cr2)} */")
        return (f"{c}\n  .byte {self.kind}, {self.b32}, {self.nslots}, {self.flags}\n"
                f"  .long {self.esp0:#010x}\n  .long {self.ss_base:#010x}\n"
                f"  .long {(self.deny if self.deny is not None else 0xFFFFFFFF):#010x}")


def pxwrap_cases():
    """The differential matrix.  Every deny case gets its permitted control
    for free: the #PF handler restores the PTE and the restarted trigger
    delivers onto the now-present wrapped stack, where the CPL0 handler
    verifies every frame byte."""
    cases = []
    # ---- group 1: B=0 (16-bit new stack), 16-bit interrupt/trap gates,
    #      with and without an error code.  SP from 0 through the frame size;
    #      SS.base low-12 in {0x000, 0xFF0, 0xFFC}; deny each touched page.
    for kind, trap, err in ((KIND_INT, 0, 0), (KIND_INT, 1, 0),
                            (KIND_GP, 0, 1), (KIND_GP, 1, 1)):
        nslots = 6 if err else 5
        size = nslots * 2
        flags = FL_G16 | (FL_TRAP if trap else 0) | (FL_ERR if err else 0)
        for base in (0x00080000, 0x00080FF0, 0x00080FFC):
            for sp in range(0, size + 1):
                probe = Case(kind, 0, nslots, flags, sp, base, None)  # dry: pages
                for pg in pages_in_order(probe.slots, 2):
                    cases.append(Case(kind, 0, nslots, flags, sp, base, pg))
    # ---- group 2: B=1 (32-bit new stack), ESP < frame size (4 GiB wrap).
    #      32-bit interrupt gate, no error code, ESP0 0..20; plus the
    #      maximal-page-count call-gate layouts.
    for esp0 in (0, 2, 4, 8, 12, 16, 20):
        probe = Case(KIND_INT, 1, 5, 0, esp0, 0, None)
        for pg in pages_in_order(probe.slots, 4):
            cases.append(Case(KIND_INT, 1, 5, 0, esp0, 0, pg))
    for esp0 in (2, 8):     # 140-byte frame on a 4 GiB-wrapped flat stack
        probe = Case(KIND_CG, 1, 35, 0, esp0, 0, None)
        for pg in pages_in_order(probe.slots, 4):
            cases.append(Case(KIND_CG, 1, 35, 0, esp0, 0, pg))
    # ---- group 4: max-parameter call gates on a B=0 new stack, SP < frame.
    #      16-bit gate pcount=31 (70-byte frame) and 32-bit gate pcount=31
    #      (140-byte frame).  (Param SOURCE reads are covered elsewhere;
    #      here only destination frame pages are denied.)
    for gate16, size in ((1, 70), (0, 140)):
        sps = (0, 34, 68, 70) if gate16 else (0, 68, 136, 140)
        for base in (0x00080000, 0x00080FFC):
            for sp in sps:
                probe = Case(KIND_CG, 0, 35, gate16 and FL_G16 or 0, sp, base, None)
                for pg in pages_in_order(probe.slots, 2 if gate16 else 4):
                    cases.append(Case(KIND_CG, 0, 35, gate16 and FL_G16 or 0,
                                      sp, base, pg))
    # ---- group 3 (permitted controls): V86 entry onto a wrapped TSS stack.
    #      Delivery must complete and land the 9/10-slot V86 frame exactly;
    #      the denials are terminal (the #PF cannot be delivered back out of
    #      a V86 context without re-using the same wrapped stack) and live in
    #      the pxwrapm witness image instead.
    cases.append(Case(KIND_V86INT, 0, 9, 0, 8, 0x00080FFC, None))    # 9-slot, B=0
    cases.append(Case(KIND_V86GP, 0, 10, 0, 4, 0x00080FFC, None))    # 10-slot, B=0
    cases.append(Case(KIND_V86INT, 1, 9, 0, 8, 0, None))             # 9-slot, B=1
    return cases


def pxwrapm_cases():
    """The zero-bytes witness subset (m0..m5) + the terminal V86 denials
    (m6, m7).  Every m-case denies a page whose first-touch slot is NOT slot
    0, so QEMU 8.2.2 (incremental pushes) leaves k_fault frame slots written
    while the probe-before-commit RTL must leave ZERO -- the graded oracle
    gap.  m6/m7 cannot recover: from V86 the #PF delivery re-probes the same
    wrapped stack, so both oracles escalate (#PF -> #DF -> shutdown/reset)."""
    m = []
    # INT16, base low-12 0xFFC, SP=8, 10-byte frame: slots k0..k3 on pages
    # 0x81/0x80 (low chunk), k4 on 0x90.  Deny 0x80000: k_fault=2 (MIDDLE
    # page -- a first/last-slot probe would miss it entirely).
    m.append(Case(KIND_INT, 0, 5, FL_G16, 8, 0x00080FFC, 0x00080000))
    # GP16 (errcode), SP=4, 12-byte frame: k0,k1 on 0x80, k2..k5 on 0x90.
    # Deny 0x90000: k_fault=2.
    m.append(Case(KIND_GP, 0, 6, FL_G16 | FL_ERR, 4, 0x00080FFC, 0x00090000))
    # INT32 on the 4 GiB wrap, ESP0=8: k0,k1 on page 0, k2..k4 on 0xFFFFF000.
    m.append(Case(KIND_INT, 1, 5, 0, 8, 0, 0xFFFFF000))             # k_fault=2
    m.append(Case(KIND_INT, 1, 5, 0, 4, 0, 0xFFFFF000))             # k_fault=1
    # CG16 pcount=31, SP=8: k0,k1 on 0x81, k2,k3 on 0x80, k4.. on 0x90.
    m.append(Case(KIND_CG, 0, 35, FL_G16, 8, 0x00080FFC, 0x00090000))  # k_fault=4
    # CG32 pcount=31, SP=8: k0 on 0x81, k1 on 0x80, k2.. on 0x90.
    m.append(Case(KIND_CG, 0, 35, 0, 8, 0x00080FFC, 0x00090000))    # k_fault=2
    # Terminal V86 denials (m6 graded on the RTL; m7 QEMU-only via reboot).
    m.append(Case(KIND_V86INT, 0, 9, 0, 8, 0x00080FFC, 0x00090000))  # k_fault=2
    m.append(Case(KIND_V86INT, 0, 9, 0, 8, 0x00080FFC, 0x00080000))  # k_fault=1
    return m


def emit(path, name, cases):
    with open(path, "w") as f:
        f.write("/* AUTO-GENERATED by gen_cases.py -- do not edit.\n"
                " * 16 bytes per case: kind, ss_b32, nslots, flags,\n"
                " * esp0, ss_base, deny_page (see gen_cases.py). */\n")
        f.write(f".equ NCASES, {len(cases)}\n")
        f.write(".section .rodata\n.align 4\ncase_table:\n")
        for c in cases:
            f.write(c.inc() + "\n")
    return len(cases)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    px = pxwrap_cases()
    pm = pxwrapm_cases()
    report_only = "--report" in sys.argv
    if not report_only:
        emit(os.path.join(here, "pxwrap_cases.inc"), "pxwrap", px)
        emit(os.path.join(here, "..", "pxwrapm", "pxwrapm_cases.inc"), "pxwrapm", pm)

    deny = [c for c in px if c.deny is not None]
    gp = [c for c in px if c.kind == KIND_GP and c.deny is not None]
    print(f"pxwrap: NCASES={len(px)} deny_cases={len(deny)} "
          f"permitted_v86={len(px) - len(deny)}")
    print(f"pxwrap: exp_pf2( vec=14 err=2 )={len(deny)}  "
          f"exp_gp60( vec=13 err=0x60 )={2 * len(gp)}  exp_df=0")
    # pxwrapm witness expectations
    pre = pm[:6]                     # m0..m5 (both oracles reach these)
    q_edi = sum(c.k_fault for c in pre)
    q_ecx = 0
    for c in pre:
        q_ecx ^= written_mask(c.k_fault)
    q_ebp = sum(c.nslots for c in pre)
    m6 = pm[6]
    print(f"pxwrapm: NCASES={len(pm)}")
    print(f"  per-case: " + "; ".join(
        f"m{i}:kflt={c.k_fault},cr2={c.cr2:#x}" for i, c in enumerate(pm)))
    print(f"  QEMU exit record: edi={q_edi:#x} esi=6 ecx={q_ecx:#x} "
          f"ebp={q_ebp:#x} ebx={pre[-1].k_fault:#x}")
    print(f"  RTL final record: edi=0 esi=6 ecx=0 ebp={q_ebp:#x} ebx=0 "
          f"cr2={m6.cr2:#x} ss=0x2000 esp=0x8000")
    print(f"  RTL faultlog: vec=14 err=2 total {6 + 3} "
          f"(6 probes + m6 cascade x3), vec=13 err=0x60 x1, vec=8 x0")


if __name__ == "__main__":
    main()
