#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""M7.3 Win95 system-replay combined-log parser (the alignment engine).

This is the shared parser that turns the SINGLE combined QEMU replay log
(`-d cpu,int,trace:memory_region_ops_read,trace:memory_region_ops_write`) into a
stream of per-instruction records aligned to the single-stepped golden, ready to
be emitted as a .vtrace by gen_trace.py --system-replay (and re-usable standalone
by parse_devlog.py).

WHY a combined log (not the gdbstub)
  qemu-system-i386 8.2.2's gdbstub is UNRESPONSIVE under `-icount rr=replay`
  (verified: it accepts the TCP connection but never answers qSupported — the
  replay engine blocks the stub's chardev). The path that DOES work under replay
  is `-accel tcg,one-insn-per-tb=on -d cpu`: QEMU dumps the FULL architectural
  register file (EAX..EDI, EIP, EFL, all six segments WITH hidden base/limit/attr,
  CR0..CR4, EFER, A20, CPL) BEFORE entering each one-instruction TB. With the int
  + memory_region_ops trace events routed to the SAME -D log, the textual order IS
  the replay-icount order, so every device-read value / delivered interrupt /
  device-write sits between the cpu-dump of the instruction that consumed it and
  the next cpu-dump. That adjacency is the alignment.

RECORD CONVENTION (matches gen_trace's user/system modes, docs/trace-format.md):
  `-d cpu` dumps the PRE-state of each instruction. So cpu-dump K is the fetch
  state of instruction K, and cpu-dump K+1 is instruction K's POST-COMMIT state.
  Record K therefore carries:
    pc        = EIP from cpu-dump K
    post regs = cpu-dump K+1's GPRs/eflags/segs/CRx   (state after insn K retires)
    dev_in    = memory_region_ops_read line(s) between dump K and dump K+1
    intr      = a "Servicing hardware INT" / seg_helper `v=` between K and K+1
    dma_wr    = memory_region_ops_write line(s) between dump K and dump K+1
  The LAST cpu-dump has no successor, so it provides only a pc and is dropped as a
  record (it is the post-state of the previous record — already emitted).

This module is stdlib-only.
"""
from __future__ import annotations

import re

# A register dump always opens with the EAX line. We collect the contiguous block
# of dump lines and parse the fields we need by regex (lenient: `-d cpu` and
# `-d int` differ in segment-line suffixes, so we anchor on the leading token).
RE_EAX = re.compile(r'^EAX=([0-9a-fA-F]{8}) EBX=([0-9a-fA-F]{8}) '
                    r'ECX=([0-9a-fA-F]{8}) EDX=([0-9a-fA-F]{8})')
RE_ESI = re.compile(r'^ESI=([0-9a-fA-F]{8}) EDI=([0-9a-fA-F]{8}) '
                    r'EBP=([0-9a-fA-F]{8}) ESP=([0-9a-fA-F]{8})')
RE_EIP = re.compile(r'^EIP=([0-9a-fA-F]{8}) EFL=([0-9a-fA-F]{8}) '
                    r'\[[^\]]*\] CPL=(\d+) II=\d+ A20=(\d+)')
# segment line, e.g.  "CS =f000 000f0000 0000ffff 00009b00 ..."
# group: selector, base, limit, attr-word (attr-word's middle byte holds the
# access-rights/type; we keep the raw 32b attr word).
RE_SEG = re.compile(r'^(ES|CS|SS|DS|FS|GS) ?=([0-9a-fA-F]{4}) '
                    r'([0-9a-fA-F]{8}) ([0-9a-fA-F]{8}) ([0-9a-fA-F]{8})')
RE_CR = re.compile(r'^CR0=([0-9a-fA-F]{8}) CR2=([0-9a-fA-F]{8}) '
                   r'CR3=([0-9a-fA-F]{8}) CR4=([0-9a-fA-F]{8})')

RE_HWINT = re.compile(r'Servicing hardware INT=0x([0-9a-fA-F]+)')
# seg_helper authoritative vector line (appears deeper in boot, in PM):
#  "v=2a e=0000 i=1 cpl=3 IP=0033:c0001234 pc=00000000 SP=0030:0000fffc ..."
RE_VEC = re.compile(
    r'\bv=([0-9a-fA-F]+)\s+e=([0-9a-fA-F]+)\s+i=(\d+)\s+'
    r'cpl=(\d+)\s+IP=([0-9a-fA-F]+:[0-9a-fA-F]+)\s+'
    r'pc=([0-9a-fA-F]+)\s+SP=([0-9a-fA-F]+:[0-9a-fA-F]+)')
RE_MRO = re.compile(
    r"memory_region_ops_(read|write)\s+cpu\s+(-?\d+)\s+mr\s+0x[0-9a-fA-F]+\s+"
    r"addr\s+0x([0-9a-fA-F]+)\s+value\s+0x([0-9a-fA-F]+)\s+"
    r"size\s+(\d+)\s+name\s+'([^']*)'")


class CpuState:
    """One parsed register dump (the pre-state of an instruction)."""
    __slots__ = ("eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi",
                 "eip", "eflags", "cpl", "a20", "seg", "seg_base", "seg_limit",
                 "seg_attr", "cr0", "cr2", "cr3", "cr4", "complete")

    def __init__(self):
        for k in ("eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi",
                  "eip", "eflags", "cpl", "a20", "cr0", "cr2", "cr3", "cr4"):
            setattr(self, k, 0)
        self.seg = {}        # name -> selector
        self.seg_base = {}   # name -> hidden base
        self.seg_limit = {}  # name -> hidden limit
        self.seg_attr = {}   # name -> raw attr word
        self.complete = False  # True once we've seen the EIP line (the anchor)


def _parse_block(lines):
    """Parse a contiguous register-dump block (list of str) into a CpuState."""
    st = CpuState()
    for ln in lines:
        m = RE_EAX.match(ln)
        if m:
            st.eax, st.ebx, st.ecx, st.edx = (int(g, 16) for g in m.groups())
            continue
        m = RE_ESI.match(ln)
        if m:
            st.esi, st.edi, st.ebp, st.esp = (int(g, 16) for g in m.groups())
            continue
        m = RE_EIP.match(ln)
        if m:
            st.eip = int(m.group(1), 16)
            st.eflags = int(m.group(2), 16)
            st.cpl = int(m.group(3))
            st.a20 = int(m.group(4))
            st.complete = True
            continue
        m = RE_SEG.match(ln)
        if m:
            name = m.group(1).lower()
            st.seg[name] = int(m.group(2), 16)
            st.seg_base[name] = int(m.group(3), 16)
            st.seg_limit[name] = int(m.group(4), 16)
            st.seg_attr[name] = int(m.group(5), 16)
            continue
        m = RE_CR.match(ln)
        if m:
            st.cr0, st.cr2, st.cr3, st.cr4 = (int(g, 16) for g in m.groups())
            continue
    return st


def iter_aligned(path, max_insn=None):
    """Stream the combined replay log and yield aligned per-instruction records.

    Yields dicts:
      {"pre": CpuState,          # pre-state (fetch) of this instruction
       "post": CpuState,         # post-commit state (next dump) or None at EOF
       "dev_in": [ {addr,val,size,region}, ... ],
       "dma_wr": [ {addr,val,size,region}, ... ],
       "intr": {vec,err?,soft?,cpl?,ip?,sp?} or None }

    The events attached are those that appeared in the log AFTER `pre`'s dump and
    BEFORE `post`'s dump (replay-icount order). Bounded by max_insn (count of
    emitted records). The trailing dump with no successor is not yielded.
    """
    # State machine. A register dump block is always emitted contiguously by QEMU
    # (EAX..EFER) and is COMPLETE before any event line or the next dump's EAX
    # line. So we accumulate dump lines into `block`; when we hit the FIRST line
    # that is NOT part of the current block (an event line OR the next EAX line),
    # the block is finished — we finalize it exactly once via `_finalize`, which
    # yields the PREVIOUS pending (its post-state is this just-finished dump) and
    # makes this dump the new pending. Event lines collected AFTER a dump (and
    # before the next dump) therefore attach to the NEXT instruction (whose
    # pre-state is that dump) — the correct replay-icount alignment. This avoids
    # the double-flush bug where an event line and the next EAX line would each
    # try to close the same block.
    state = {"pending": None, "block": [], "emitted": 0,
             "dev_in": [], "dma_wr": [], "intr": None}

    def finalize_block():
        """Finish the current dump block (if any): yield prior record, advance.

        Returns the just-finished CpuState (now `pending`) or None if `block`
        held no complete dump. Yields zero-or-one aligned record as a side effect
        via the closure list `_out` (we collect then re-yield in the caller)."""
        blk = state["block"]
        if not blk:
            return None
        st = _parse_block(blk)
        state["block"] = []
        if not st.complete:
            return None
        out = None
        if state["pending"] is not None:
            out = {"pre": state["pending"], "post": st,
                   "dev_in": state["dev_in"], "dma_wr": state["dma_wr"],
                   "intr": state["intr"]}
            state["dev_in"], state["dma_wr"], state["intr"] = [], [], None
        state["pending"] = st
        return out

    DUMP_CONT = ("LDT=", "TR =", "GDT=", "IDT=", "DR0=", "DR6=", "CCS=", "EFER=",
                 "FPR", "XMM", "MXCSR")

    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            # A continuation of the in-progress register dump?
            if state["block"] and (RE_ESI.match(line) or RE_EIP.match(line)
                                   or RE_SEG.match(line) or RE_CR.match(line)
                                   or line.startswith(DUMP_CONT)):
                state["block"].append(line)
                continue
            # The start of a NEW register dump?  (EAX line opens a block.)
            if RE_EAX.match(line):
                out = finalize_block()       # close the PREVIOUS dump, if any
                if out is not None:
                    yield out
                    state["emitted"] += 1
                    if max_insn is not None and state["emitted"] >= max_insn:
                        return
                state["block"].append(line)
                continue
            # Otherwise it's an event line (or a marker like "SMM: enter").
            # Close the current dump block first (so its state becomes `pending`
            # and the prior record is yielded), THEN attach this event to the
            # next instruction's buffers.
            out = finalize_block()
            if out is not None:
                yield out
                state["emitted"] += 1
                if max_insn is not None and state["emitted"] >= max_insn:
                    return
            dev_in = state["dev_in"]
            dma_wr = state["dma_wr"]
            m = RE_MRO.search(line)
            if m:
                rec = {"addr": int(m.group(3), 16), "val": int(m.group(4), 16),
                       "size": int(m.group(5)), "region": m.group(6)}
                if m.group(1) == "read":
                    dev_in.append(rec)
                else:
                    dma_wr.append(rec)
                continue
            m = RE_VEC.search(line)
            if m:
                # Authoritative seg_helper line: vector + errcode + boundary. This
                # supersedes any preceding async-marker intr for this boundary.
                state["intr"] = {"vec": int(m.group(1), 16),
                                 "err": int(m.group(2), 16),
                                 "soft": (m.group(3) == "1"),
                                 "cpl": int(m.group(4)),
                                 "ip": m.group(5), "sp": m.group(7)}
                continue
            m = RE_HWINT.search(line)
            if m:
                # async IRQ delivery marker — vec only (no errcode/boundary).
                # If a richer seg_helper line follows it overwrites this with the
                # authoritative boundary; otherwise this stands as the intr.
                if state["intr"] is None:
                    state["intr"] = {"vec": int(m.group(1), 16), "soft": False}
                continue
    # EOF: finalize the trailing dump block. If it completes a pairing
    # (pending + this final dump as its post-state), yield that last record. The
    # dump that BECOMES pending after this final finalize has NO successor, so it
    # is the post-state of the just-yielded record (already accounted for) and is
    # NOT itself yielded — there is no post-commit state to carry for it.
    out = finalize_block()
    if out is not None:
        if max_insn is None or state["emitted"] < max_insn:
            yield out
