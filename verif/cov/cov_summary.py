#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Summarize a Verilator coverage .dat (line + toggle) into per-file and overall
covered/total percentages, and rank the least-covered files so the next coverage
iteration knows where to aim.

Verilator .dat record format (one coverage point per line):
    C '<\\x01key\\x02value...>' <count>
keys we use:  f=filename  l=line  page=v_line.../v_toggle...  (count>0 => hit)
"""
from __future__ import annotations
import argparse, json, os, re, sys

REC = re.compile(r"^C '(.*)' (\d+)\s*$")


def parse_dat(path: str):
    """Yield (filename, kind, count) for every coverage point.

    kind is 'line' or 'toggle' (derived from the page prefix). Points whose page
    is neither are skipped (e.g. v_user assertion points if ever enabled).
    """
    with open(path, "r", errors="replace") as f:
        for line in f:
            m = REC.match(line.rstrip("\n"))
            if not m:
                continue
            content, count = m.group(1), int(m.group(2))
            fields = {}
            for tok in content.split("\x01"):
                if not tok:
                    continue
                if "\x02" in tok:
                    k, v = tok.split("\x02", 1)
                    fields[k] = v
            page = fields.get("page", "")
            if page.startswith("v_line"):
                kind = "line"
            elif page.startswith("v_toggle"):
                kind = "toggle"
            else:
                continue
            yield fields.get("f", "?"), kind, count


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dat", help="merged coverage .dat")
    ap.add_argument("--root", default=None,
                    help="strip this prefix from filenames in the report")
    ap.add_argument("--json", default=None, help="write machine-readable summary")
    ap.add_argument("--out", default=None, help="write the text report here too")
    ap.add_argument("--worst", type=int, default=20,
                    help="show this many least-covered files")
    args = ap.parse_args()

    if not os.path.exists(args.dat):
        sys.exit(f"cov_summary: {args.dat} not found")

    # per-file: {kind: [covered, total]}
    per = {}
    tot = {"line": [0, 0], "toggle": [0, 0]}
    for fn, kind, count in parse_dat(args.dat):
        d = per.setdefault(fn, {"line": [0, 0], "toggle": [0, 0]})
        d[kind][1] += 1
        tot[kind][1] += 1
        if count > 0:
            d[kind][0] += 1
            tot[kind][0] += 1

    def pct(c, t):
        return (100.0 * c / t) if t else 100.0

    def short(fn):
        if args.root and fn.startswith(args.root):
            return fn[len(args.root):].lstrip("/")
        return fn

    lines = []
    lines.append("=" * 78)
    lines.append("Verilator code-coverage summary  (line + toggle)")
    lines.append("=" * 78)
    lc, lt = tot["line"]; tc, tt = tot["toggle"]
    lines.append(f"LINE   coverage: {lc:7d}/{lt:<7d}  {pct(lc, lt):6.2f}%")
    lines.append(f"TOGGLE coverage: {tc:7d}/{tt:<7d}  {pct(tc, tt):6.2f}%")
    allc, allt = lc + tc, lt + tt
    lines.append(f"OVERALL points : {allc:7d}/{allt:<7d}  {pct(allc, allt):6.2f}%")
    lines.append("")

    # ---- per-file table (sorted by combined coverage ascending) -------------
    rows = []
    for fn, d in per.items():
        c = d["line"][0] + d["toggle"][0]
        t = d["line"][1] + d["toggle"][1]
        rows.append((pct(c, t), fn, d))
    rows.sort(key=lambda r: (r[0], r[1]))

    lines.append("-" * 78)
    lines.append(f"{args.worst} LEAST-COVERED files  (line% / toggle% / combined%)")
    lines.append("-" * 78)
    lines.append(f"  {'file':40s} {'line':>8s} {'tog':>8s} {'comb':>8s}")
    for combined, fn, d in rows[:args.worst]:
        lp = pct(d["line"][0], d["line"][1])
        tp = pct(d["toggle"][0], d["toggle"][1])
        lines.append(f"  {short(fn)[-40:]:40s} {lp:7.1f}% {tp:7.1f}% {combined:7.1f}%")
    lines.append("")
    lines.append("-" * 78)
    lines.append("ALL files (combined% ascending)")
    lines.append("-" * 78)
    for combined, fn, d in rows:
        lp = pct(d["line"][0], d["line"][1])
        tp = pct(d["toggle"][0], d["toggle"][1])
        lines.append(f"  {short(fn):52s} L{lp:6.1f}% T{tp:6.1f}% C{combined:6.1f}%")

    text = "\n".join(lines)
    print(text)
    if args.out:
        open(args.out, "w").write(text + "\n")
    if args.json:
        json.dump({
            "line": {"covered": lc, "total": lt, "pct": pct(lc, lt)},
            "toggle": {"covered": tc, "total": tt, "pct": pct(tc, tt)},
            "overall": {"covered": allc, "total": allt, "pct": pct(allc, allt)},
            "files": {short(fn): {
                "line": d["line"], "toggle": d["toggle"],
                "combined_pct": pct(d["line"][0] + d["toggle"][0],
                                    d["line"][1] + d["toggle"][1]),
            } for _, fn, d in rows},
        }, open(args.json, "w"), indent=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
