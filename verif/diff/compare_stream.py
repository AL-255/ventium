#!/usr/bin/env python3
"""Streaming functional comparator for LARGE lock-step traces (M7 macro-workloads).

compare.py loads both traces fully into memory; a multi-million-record Quake/Win95
lock-step would exceed RAM. This streams both .vtrace files line-by-line (records are
aligned by `n`, retire order) and applies the IDENTICAL func grading as compare.py —
the same key set (tracefmt.func_compare_keys) and the same EFLAGS masking
(compare._eflags_equal with tracefmt.EFLAGS_DEFAULT_MASK + per-instruction
undefined-flag removal). O(1) memory; stops at the first divergence.

  compare_stream.py <golden.vtrace> <rtl.vtrace> [--sys] [--max N]

Exit 0 = EQUIVALENT over the compared prefix; 1 = DIVERGENT (first shown).
"""
import json
import sys
import argparse
import tracefmt
import compare as cmp


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("golden")
    ap.add_argument("rtl")
    ap.add_argument("--sys", action="store_true", help="compare cr0..cr4 too")
    ap.add_argument("--max", type=int, default=None, help="cap records compared")
    a = ap.parse_args()

    keys = tracefmt.func_compare_keys(x87=False, sys=a.sys)
    base_mask = tracefmt.EFLAGS_DEFAULT_MASK
    n = 0
    with open(a.golden) as fa, open(a.rtl) as fc:
        ha, hc = fa.readline(), fc.readline()           # header lines
        if '"vtrace"' not in ha or '"vtrace"' not in hc:
            print("compare_stream: missing .vtrace header", file=sys.stderr)
            return 2
        for la, lc in zip(fa, fc):
            if a.max is not None and n >= a.max:
                break
            ra, rc = json.loads(la), json.loads(lc)
            na, nc = ra.get("n"), rc.get("n")
            if na != nc:
                print(f"RESULT: DIVERGENT  n misalign A={na} C={nc} (record {n})")
                return 1
            mnem = cmp._mnemonic_from_bytes(ra.get("bytes")) \
                or cmp._mnemonic_from_bytes(rc.get("bytes"))
            for f in keys:
                va, vc = ra.get(f), rc.get(f)
                if va is None and vc is None:
                    continue
                if va is None or vc is None:
                    print(f"RESULT: DIVERGENT (field present one side)\n"
                          f"  n={na} pc={ra.get('pc')} field={f} "
                          f"A={va} C={vc}")
                    return 1
                if f == "eflags":
                    eq, eff = cmp._eflags_equal(va, vc, base_mask, mnem)
                    if not eq:
                        print(f"RESULT: DIVERGENT\n  n={na} pc={ra.get('pc')} "
                              f"field=eflags(mask={tracefmt.hx(eff,32)}) "
                              f"A={va} C={vc}")
                        return 1
                elif va != vc:
                    print(f"RESULT: DIVERGENT\n  n={na} pc={ra.get('pc')} "
                          f"field={f} A={va} C={vc}")
                    return 1
            n += 1
    print(f"RESULT: EQUIVALENT ({n} records match, streamed; "
          f"eflags base mask {tracefmt.hx(base_mask,32)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
