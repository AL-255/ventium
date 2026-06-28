#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Parse ref.x86asm.net's x86reference.xml and emit the authoritative list of
Pentium-P54C opcodes that the regression suite must test — SCRIPT-GENERATED so
no opcode is missed by hand. Each in-scope opcode encoding is emitted with the
metadata the test generator needs (mnemonic, full opcode bytes, operand methods,
ModRM/SIB/immediate flags, group /digit, mandatory prefix, x87-ness).

P54C scope:  proc_start <= 5  (8086/186/286/386/486/Pentium) + the base
instructions with no proc_start; MMX (6), SSE/PPro (7+) and 64-bit-only forms
are EXCLUDED. The plain Pentium has x87 but NOT MMX.

Output:  opspec.json (machine-readable) + opspec.txt (human checklist).
"""
from __future__ import annotations
import xml.etree.ElementTree as ET
import json, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
XML = os.path.join(HERE, "x86reference.xml")

# proc_start index -> first CPU.  We keep <= 5 (Pentium / P54C) + 'none' (8086).
PROC_MAX = 5   # 5 = Pentium (P5/P54C); 6 = Pentium-MMX (excluded)

# Addressing methods that imply a ModRM byte (Intel SDM A.2.1).
MODRM_METHODS = set("CDEGMNPQRSTUVW")     # all use ModRM
# ...of those, the ones whose r/m may select memory (=> SIB possible in 32-bit).
MODRM_MEM_METHODS = set("EMQW")           # E/M/Q/W can be a memory r/m
# methods whose r/m must be a register (mod=11 only): N,P(reg),R,U and reg-side G,S,V,C,D,T
# immediate / relative / direct-offset methods
IMM_METHODS = set("IJ")
# register-in-opcode (no ModRM): Z (low 3 bits of opcode), O (moffs)


def text(el, tag):
    c = el.find(tag)
    return c.text if c is not None and c.text else None


def operands(entry):
    """Return list of (kind, method, type) for an entry's first syntax.

    kind in {dst,src}; method is the <a> addressing method (E,G,I,...); type the
    <t> operand-type (b, vqp, ...). Some operands are literal registers (<a>
    absent, the element text names the reg) — captured as method '#'.
    """
    out = []
    syn = entry.find("syntax")
    if syn is None:
        return out, (text(syn, "mnem") if syn is not None else None)
    mnem = text(syn, "mnem")
    for od in syn:
        if od.tag not in ("dst", "src"):
            continue
        a = od.find("a")
        t = od.find("t")
        meth = a.text if a is not None and a.text else "#"
        typ = t.text if t is not None and t.text else (od.text.strip() if od.text else "")
        # implicit/displayed-only operands carry displayed="no"? keep them anyway
        out.append((od.tag, meth, typ))
    return out, mnem


def in_scope(entry):
    ps = text(entry, "proc_start")
    if ps is not None:
        try:
            if int(ps) > PROC_MAX:
                return False
        except ValueError:
            return False
    # exclude explicitly-undefined / invalid / alias-of-future rows
    if entry.get("is_undoc") == "1" and entry.get("ring") is None:
        pass  # keep documented-undocumented P5 errata ops if present; harmless
    return True


def main():
    if not os.path.exists(XML):
        sys.exit(f"{XML} not found — download x86reference.xml first")
    root = ET.parse(XML).getroot()
    specs = []
    skipped_proc = 0

    for mapname, esc in (("one-byte", ""), ("two-byte", "0F")):
        m = root.find(mapname)
        for po in m.findall("pri_opcd"):
            opval = po.get("value")          # hex string e.g. "00", "AF"
            for entry in po.findall("entry"):
                if not in_scope(entry):
                    skipped_proc += 1
                    continue
                ops, mnem = operands(entry)
                if not mnem:
                    continue
                methods = [m_ for (_k, m_, _t) in ops]
                # SSE/MMX register methods leaking past the proc filter -> drop
                if any(mm in ("V", "W", "U", "P", "N", "Q") for mm in methods):
                    continue
                has_modrm = (entry.get("r") == "yes") or \
                            any(mm in MODRM_METHODS for mm in methods)
                ext = text(entry, "opcd_ext")          # the /digit (group)
                if ext is not None:
                    has_modrm = True
                sib = any(mm in MODRM_MEM_METHODS for mm in methods) or \
                      (ext is not None and not entry.get("mod") == "11")
                pref = text(entry, "pref")             # mandatory prefix (66/F2/F3/9B)
                sec = text(entry, "sec_opcd")          # x87 reg-form byte (F0..FF, C9..)
                mod_a = entry.get("mod")               # 'mem' / 'nomem' / None
                doc = entry.get("doc")                 # 'u' = undocumented
                palias = entry.get("part_alias")       # set => a redundant alias encoding
                imm = [t for (_k, mm, t) in ops if mm in IMM_METHODS]
                is_x87 = any(mm in ("EST", "ES") for mm in methods) or \
                         opval in ("D8", "D9", "DA", "DB", "DC", "DD", "DE", "DF")
                # register-in-opcode low-3-bits (Z/O methods) => 8 opcode variants
                regop = any(mm in ("Z", "O") for mm in methods)

                specs.append({
                    "map": mapname,
                    "opcode": (esc + " " if esc else "") + opval,
                    "esc": esc,
                    "opval": opval,
                    "mnem": mnem,
                    "operands": [{"k": k, "a": mm, "t": t} for (k, mm, t) in ops],
                    "has_modrm": bool(has_modrm),
                    "opcd_ext": ext,                  # group /digit or None
                    "sec_opcd": sec,                  # x87/2nd-byte reg-form selector
                    "mod_attr": mod_a,                # mem / nomem (x87 form)
                    "doc": doc,                       # 'u' undocumented
                    "part_alias": palias,             # redundant alias encoding
                    "sib_possible": bool(sib),
                    "pref": pref,
                    "imm": imm,
                    "is_x87": bool(is_x87),
                    "regop_low3": bool(regop),
                    "proc_start": text(entry, "proc_start") or "none",
                    "lock": entry.get("lock") == "yes",
                    "direction": entry.get("direction"),
                    "op_size": entry.get("op_size"),
                })

    # de-dup identical (opcode, mnem, opcd_ext, pref) keeping first
    seen = set(); uniq = []
    for s in specs:
        # sec_opcd + mod_attr distinguish the x87 reg-form ops that share opcode+
        # /digit (F2XM1..FCOS, FCHS, FNOP, ...) — without them they collapse to one.
        key = (s["opcode"], s["mnem"], s["opcd_ext"], s["sec_opcd"], s["mod_attr"],
               s["pref"], tuple(o["a"]+o["t"] for o in s["operands"]))
        if key in seen:
            continue
        seen.add(key); uniq.append(s)

    json.dump(uniq, open(os.path.join(HERE, "opspec.json"), "w"), indent=1)

    # human checklist
    lines = []
    lines.append(f"P54C opcode test checklist — {len(uniq)} encodings "
                 f"(proc_start<= {PROC_MAX}; MMX/SSE/PPro excluded; {skipped_proc} future-proc skipped)")
    lines.append("=" * 78)
    n_modrm = sum(1 for s in uniq if s["has_modrm"])
    n_grp = sum(1 for s in uniq if s["opcd_ext"] is not None)
    n_x87 = sum(1 for s in uniq if s["is_x87"])
    n_sib = sum(1 for s in uniq if s["sib_possible"])
    lines.append(f"  with ModRM: {n_modrm}   group /digit: {n_grp}   SIB-capable: {n_sib}   x87: {n_x87}")
    lines.append("")
    for s in uniq:
        ext = f"/{s['opcd_ext']}" if s["opcd_ext"] is not None else ""
        pref = f"[{s['pref']}]" if s["pref"] else ""
        ops = ",".join(f"{o['a']}{o['t']}" for o in s["operands"])
        flags = "".join(c for c, on in (("M", s["has_modrm"]), ("S", s["sib_possible"]),
                                        ("I", bool(s["imm"])), ("X", s["is_x87"]),
                                        ("Z", s["regop_low3"])) if on)
        lines.append(f"  {s['opcode']:>5}{ext:<3}{pref:<5} {s['mnem']:<10} {ops:<22} [{flags}]")
    open(os.path.join(HERE, "opspec.txt"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines[:6]))
    print(f"... wrote opspec.json ({len(uniq)} encodings) + opspec.txt")


if __name__ == "__main__":
    main()
