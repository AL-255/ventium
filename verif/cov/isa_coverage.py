#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Retired-instruction ISA-coverage analyzer for the Ventium coverage suite.

The premise of this tool is "retired instructions are what is ACTUALLY executed":
rather than statically disassembling a test's whole image (which counts bytes the
core may never reach), we walk the RTL .vtrace — one record per RETIRED
instruction, in architectural order — and decode the instruction at each retired
PC out of the loaded flat image. That yields:

  * an executed-opcode histogram (per-mnemonic + per opcode-map cell), i.e. the
    ISA the corpus genuinely exercises on real silicon-model retirement, and
  * an "unimplemented / diverging instruction" report: when a golden QEMU trace
    is supplied, the first instruction the RTL FAILS to retire (it stopped short,
    the d_unknown -> S_HALT signature) or the first PC where the RTL stream
    diverges from the golden is decoded and named — that is the gap to fix.

Two modes:
  analyze  one test -> a per-test JSON artifact (call once per program)
  report   aggregate all per-test JSONs -> the executed-ISA + unimplemented report
"""
from __future__ import annotations
import argparse, json, os, sys, glob

# Reuse the canonical trace parser (field names never drift from the producers).
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "diff"))
import tracefmt  # noqa: E402

try:
    from capstone import Cs, CS_ARCH_X86, CS_MODE_32
except ImportError:
    sys.exit("isa_coverage: python 'capstone' module required (pip install capstone)")

# Legacy prefix bytes skipped to reach the true opcode (so the opcode-map cell is
# the actual operation, not 0x66/0xF3/segment-override noise).
_PREFIXES = {0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65}


def _h(v: str | int) -> int:
    return v if isinstance(v, int) else int(v, 16)


def opcode_cell(raw: bytes) -> str:
    """Canonical opcode-map cell for an instruction's raw bytes.

    Skips legacy prefixes, then keys on the primary opcode; two-byte 0F escapes
    become "0F xx" (the secondary opcode map). Used to tally ISA-map coverage.
    """
    i = 0
    while i < len(raw) and raw[i] in _PREFIXES:
        i += 1
    if i >= len(raw):
        return "??"
    op = raw[i]
    if op == 0x0F and i + 1 < len(raw):
        return f"0F {raw[i+1]:02X}"
    return f"{op:02X}"


def load_image(path: str, base: int):
    with open(path, "rb") as f:
        return bytearray(f.read()), base


def decode_at(md: Cs, img: bytes, base: int, pc: int):
    """Decode ONE instruction at virtual address pc from the flat image.

    Returns (mnemonic, op_str, raw_bytes, size) or None if pc is outside the
    image or capstone can't decode it (a wild jump / non-code target).
    """
    off = pc - base
    if off < 0 or off >= len(img):
        return None
    window = bytes(img[off:off + 15])  # max x86 insn length
    for insn in md.disasm(window, pc, count=1):
        return (insn.mnemonic, insn.op_str, bytes(insn.bytes), insn.size)
    return None


def analyze(args) -> int:
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    img, base = load_image(args.flat, _h(args.load))

    rtl = tracefmt.read_trace(args.rtl)
    rtl_pcs = [_h(r["pc"]) for r in rtl.records]

    mnem: dict[str, int] = {}
    cells: dict[str, int] = {}
    undecoded = 0
    for pc in rtl_pcs:
        d = decode_at(md, img, base, pc)
        if d is None:
            undecoded += 1
            continue
        mn, _opstr, raw, _sz = d
        mnem[mn] = mnem.get(mn, 0) + 1
        cells[opcode_cell(raw)] = cells.get(opcode_cell(raw), 0) + 1

    # ---- unimplemented / divergence detection vs the golden -----------------
    status = "ok"
    first_problem = None
    golden_retired = None
    if args.golden and os.path.exists(args.golden):
        gold = tracefmt.read_trace(args.golden)
        gold_pcs = [_h(r["pc"]) for r in gold.records]
        golden_retired = len(gold_pcs)
        # Find the first index where the streams differ (or where RTL ran out).
        n = min(len(rtl_pcs), len(gold_pcs))
        diverge_i = None
        for i in range(n):
            if rtl_pcs[i] != gold_pcs[i]:
                diverge_i = i
                break
        if diverge_i is not None:
            status = "diverge"
            bad_pc = gold_pcs[diverge_i]
        elif len(rtl_pcs) < len(gold_pcs):
            # RTL retired fewer instructions and never diverged on the common
            # prefix => it STOPPED at the next golden instruction. That is the
            # d_unknown -> S_HALT (unimplemented opcode) signature.
            status = "short"
            bad_pc = gold_pcs[len(rtl_pcs)]
        else:
            bad_pc = None
        if bad_pc is not None:
            d = decode_at(md, img, base, bad_pc)
            if d:
                mn, opstr, raw, _sz = d
                first_problem = {
                    "pc": f"0x{bad_pc:08x}",
                    "bytes": raw.hex(),
                    "cell": opcode_cell(raw),
                    "mnemonic": mn,
                    "text": f"{mn} {opstr}".strip(),
                }
            else:
                first_problem = {
                    "pc": f"0x{bad_pc:08x}", "bytes": "", "cell": "??",
                    "mnemonic": "<undecodable>", "text": "<undecodable target>",
                }

    out = {
        "name": args.name,
        "rtl_retired": len(rtl_pcs),
        "golden_retired": golden_retired,
        "undecoded_pcs": undecoded,
        "mnemonics": mnem,
        "opcode_cells": cells,
        "status": status,
        "first_problem": first_problem,
    }
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2)
    tag = {"ok": "OK", "short": "STOPPED-SHORT", "diverge": "DIVERGED"}[status]
    extra = ""
    if first_problem:
        extra = f"  @ {first_problem['pc']} {first_problem['text']} [{first_problem['cell']}]"
    print(f"isa-cov {args.name}: {tag}  rtl={len(rtl_pcs)} "
          f"golden={golden_retired}  distinct-opcodes={len(cells)}{extra}")
    return 0


def report(args) -> int:
    files = sorted(glob.glob(os.path.join(args.dir, "*.isa.json")))
    if not files:
        sys.exit(f"isa_coverage report: no *.isa.json under {args.dir}")

    mnem: dict[str, int] = {}
    cells: dict[str, int] = {}
    problems = []   # (name, status, first_problem)
    total_rtl = 0
    n_ok = n_short = n_diverge = 0
    for fp in files:
        d = json.load(open(fp))
        total_rtl += d.get("rtl_retired", 0)
        for k, v in d.get("mnemonics", {}).items():
            mnem[k] = mnem.get(k, 0) + v
        for k, v in d.get("opcode_cells", {}).items():
            cells[k] = cells.get(k, 0) + v
        st = d.get("status", "ok")
        if st == "ok":
            n_ok += 1
        else:
            if st == "short":
                n_short += 1
            elif st == "diverge":
                n_diverge += 1
            problems.append((d["name"], st, d.get("first_problem")))

    lines = []
    lines.append("=" * 72)
    lines.append("Ventium ISA execution coverage  (retired instructions == executed)")
    lines.append("=" * 72)
    lines.append(f"tests analyzed     : {len(files)}")
    lines.append(f"  clean (ok)       : {n_ok}")
    lines.append(f"  stopped-short    : {n_short}   (suspected UNIMPLEMENTED opcode)")
    lines.append(f"  diverged         : {n_diverge}   (control-flow / value bug)")
    lines.append(f"retired insns total: {total_rtl}")
    lines.append(f"distinct opcode-map cells executed: {len(cells)}")
    lines.append(f"distinct mnemonics executed       : {len(mnem)}")
    lines.append("")

    # ---- unimplemented / problem report (the gaps to fix) -------------------
    lines.append("-" * 72)
    lines.append("UNIMPLEMENTED / DIVERGING INSTRUCTIONS (first problem per test)")
    lines.append("-" * 72)
    if not problems:
        lines.append("  (none — every test's retired stream matches its golden)")
    else:
        # Group by the offending opcode cell so duplicates collapse to one gap.
        by_cell: dict[str, list] = {}
        for name, st, fp in problems:
            cell = (fp or {}).get("cell", "??")
            by_cell.setdefault(cell, []).append((name, st, fp))
        for cell in sorted(by_cell):
            entries = by_cell[cell]
            ex = entries[0][2] or {}
            lines.append(f"  [{cell}] {ex.get('mnemonic','?'):10s} "
                         f"e.g. \"{ex.get('text','?')}\"  "
                         f"({len(entries)} test(s))")
            for name, st, fp in entries:
                fpc = (fp or {}).get("pc", "?")
                lines.append(f"        - {name:18s} {st:6s} @ {fpc}")
    lines.append("")

    # ---- executed opcode-map cells ------------------------------------------
    lines.append("-" * 72)
    lines.append("EXECUTED opcode-map cells (cell: count)")
    lines.append("-" * 72)
    row = []
    for cell in sorted(cells):
        row.append(f"{cell}:{cells[cell]}")
        if len(row) == 6:
            lines.append("  " + "  ".join(row)); row = []
    if row:
        lines.append("  " + "  ".join(row))
    lines.append("")

    # ---- executed mnemonics -------------------------------------------------
    lines.append("-" * 72)
    lines.append("EXECUTED mnemonics (sorted by frequency)")
    lines.append("-" * 72)
    for mn, c in sorted(mnem.items(), key=lambda kv: (-kv[1], kv[0])):
        lines.append(f"  {mn:12s} {c}")

    text = "\n".join(lines)
    print(text)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")
    # Machine-readable aggregate alongside the text report.
    if args.json:
        json.dump({
            "tests": len(files), "ok": n_ok, "short": n_short, "diverge": n_diverge,
            "retired_total": total_rtl, "opcode_cells": cells, "mnemonics": mnem,
            "problems": [{"name": n, "status": s, "first_problem": p}
                         for (n, s, p) in problems],
        }, open(args.json, "w"), indent=2)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("analyze", help="analyze one test's retired stream")
    a.add_argument("--name", required=True)
    a.add_argument("--rtl", required=True, help="RTL .vtrace")
    a.add_argument("--flat", required=True, help="flat image the test ran")
    a.add_argument("--load", required=True, help="image base (hex)")
    a.add_argument("--golden", default=None, help="QEMU golden .vtrace (optional)")
    a.add_argument("--out", required=True, help="per-test JSON artifact")
    a.set_defaults(fn=analyze)

    r = sub.add_parser("report", help="aggregate per-test JSONs into a report")
    r.add_argument("--dir", required=True, help="dir of *.isa.json artifacts")
    r.add_argument("--out", default=None, help="write the text report here too")
    r.add_argument("--json", default=None, help="write a machine-readable aggregate")
    r.set_defaults(fn=report)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
