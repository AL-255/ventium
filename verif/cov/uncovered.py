#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""List the UNCOVERED coverage points in a Verilator .dat, so the coverage loop
knows the exact source lines / toggles still to hit.

Usage:
  uncovered.py merged.dat --kind line   --match rtl/core --match rtl/fpu
  uncovered.py merged.dat --kind toggle --match rtl/core/core.sv --context

`line`   points print as  <file>:<line>   (one per uncovered statement).
`toggle` points print as  <file>:<line> <signal>:<edge>.
With --src, the source line text is shown next to each uncovered line.
"""
from __future__ import annotations
import argparse, re, os, sys
from collections import defaultdict

REC = re.compile(r"^C '(.*)' (\d+)\s*$")


def fields(content: str) -> dict:
    d = {}
    for tok in content.split("\x01"):
        if "\x02" in tok:
            k, v = tok.split("\x02", 1)
            d[k] = v
    return d


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dat")
    ap.add_argument("--kind", choices=["line", "toggle"], default="line")
    ap.add_argument("--match", action="append", default=[],
                    help="only files containing this substring (repeatable)")
    ap.add_argument("--src", action="store_true", help="show source line text")
    ap.add_argument("--counts", action="store_true",
                    help="just print per-file uncovered counts, sorted desc")
    args = ap.parse_args()

    # uncovered[file] = set/list of (line, detail)
    unc = defaultdict(list)
    seen = set()
    with open(args.dat, "r", errors="replace") as f:
        for ln in f:
            m = REC.match(ln.rstrip("\n"))
            if not m:
                continue
            fl = fields(m.group(1))
            count = int(m.group(2))
            page = fl.get("page", "")
            kind = "line" if page.startswith("v_line") else \
                   "toggle" if page.startswith("v_toggle") else None
            if kind != args.kind:
                continue
            fn = fl.get("f", "?")
            if args.match and not any(s in fn for s in args.match):
                continue
            line = fl.get("l", "?")
            # toggle detail: the signal name (o field) + transition
            detail = fl.get("o", "") if args.kind == "toggle" else ""
            key = (fn, line, detail)
            # a line point can appear once; toggle points: keep uncovered only
            if count == 0:
                if key not in seen:
                    seen.add(key)
                    unc[fn].append((int(line) if line.isdigit() else line, detail))
            else:
                # mark covered so a later 0-count duplicate doesn't re-add
                seen.add(key)

    # drop any (fn,line,detail) that ALSO has a covered instance — for line
    # coverage Verilator emits one point per line, so this is just the 0-count set.
    if args.counts:
        rows = sorted(((len(v), fn) for fn, v in unc.items()), reverse=True)
        for n, fn in rows:
            print(f"{n:5d}  {fn}")
        print(f"\ntotal uncovered {args.kind} points: {sum(n for n,_ in rows)} "
              f"across {len(rows)} files")
        return 0

    src_cache = {}
    def srcline(fn, line):
        if not args.src or not isinstance(line, int):
            return ""
        if fn not in src_cache:
            try:
                src_cache[fn] = open(fn, errors="replace").read().splitlines()
            except OSError:
                src_cache[fn] = []
        lines = src_cache[fn]
        return lines[line - 1].strip() if 0 < line <= len(lines) else ""

    for fn in sorted(unc):
        pts = sorted(unc[fn], key=lambda t: (t[0] if isinstance(t[0], int) else 1<<30, t[1]))
        print(f"\n## {fn}  ({len(pts)} uncovered {args.kind})")
        for line, detail in pts:
            tail = f"  {detail}" if detail else ""
            s = srcline(fn, line)
            print(f"  {fn}:{line}{tail}" + (f"   | {s}" if s else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
