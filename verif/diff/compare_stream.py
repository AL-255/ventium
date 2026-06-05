#!/usr/bin/env python3
"""Streaming functional comparator for LARGE lock-step traces (M7 macro-workloads).

compare.py loads both traces fully into memory; a multi-million-record Quake/Win95
lock-step would exceed RAM. This streams both .vtrace files line-by-line (records are
aligned by `n`, retire order) and applies the IDENTICAL func grading as compare.py —
the same key set (tracefmt.func_compare_keys) and the same EFLAGS masking
(compare._eflags_equal with tracefmt.EFLAGS_DEFAULT_MASK + per-instruction
undefined-flag removal). O(1) memory; stops at the first divergence.

  compare_stream.py <golden.vtrace> <rtl.vtrace> [--sys] [--max N] [--dedup-golden]

Exit 0 = EQUIVALENT over the compared prefix; 1 = DIVERGENT (first shown).

--dedup-golden (M7.3c): collapse consecutive ARCHITECTURAL duplicate records in the
GOLDEN stream. The Win95 producer captures with qemu `-accel tcg,one-insn-per-tb=on
-d cpu`, which for a handful of instructions (9 of 300000 in the bounded prefix —
mid-`rep movsb` / `rep insb` re-entries and a few TB-boundary re-dumps) emits the
architectural state TWICE for the SAME retirement: a golden record whose ENTIRE
architectural state (pc + all GPRs + eflags + the six selectors + cr0..cr4 + every
segment-hidden base/limit/attr) is identical to its immediate predecessor. Two
consecutive records with byte-identical FULL architectural state (the pc included)
cannot be two distinct instruction retirements — a real second instruction must
change at least eip (or, for a self-jump, never make forward progress, which these do
not: the stream always advances on the following record). So such a record carries
ZERO new architectural information and is provably a tracer re-dump, not a CPU event.
(The dedup key is the architectural fields ONLY — the same set the comparator grades —
so a re-dump that merely drops the `dev_in` annotation of the real preceding IN still
collapses; the environment is not part of the CPU-architectural delta being checked.)
This flag skips ONLY those architectural duplicates in the golden (reporting the
count), re-aligning the RTL's one-record-per-retirement stream. It does NOT relax the
field comparison itself (every surviving record is graded byte-for-byte by the same
strict keys + EFLAGS mask) — an alignment fix on a known producer artifact, NOT a
comparator weakening. Default OFF (so the strict self-compare path is unchanged).
"""
import json
import sys
import argparse
import tracefmt
import compare as cmp


# Architectural identity = exactly the fields the comparator grades (func keys for
# the sys profile) PLUS the segment-hidden descriptor cache. The environment fields
# (dev_in / dma_wr / intr / bytes) are deliberately EXCLUDED: they annotate a
# retirement but are not part of the CPU-architectural state, so a bare TB-boundary
# re-dump that drops them is still the same architectural point.
_ARCH_KEYS = tuple(tracefmt.func_compare_keys(x87=False, sys=True)) + tuple(
    f"{s}_{suf}" for s in tracefmt.SEG_KEYS for suf in ("base", "limit", "attr"))


def _golden_records(fa, dedup):
    """Yield (record, n_collapsed_so_far) golden records, optionally collapsing
    consecutive ARCHITECTURAL duplicates (the _ARCH_KEYS subset identical to the
    previously-yielded record). Only a verbatim re-dump of the SAME architectural
    point (pc + all registers/flags/segs/CRs/seg-hidden) is ever skipped. Returns the
    running collapsed count alongside each yielded record."""
    prev_key = None
    collapsed = 0
    for la in fa:
        ra = json.loads(la)
        if dedup:
            key = tuple(ra.get(k) for k in _ARCH_KEYS)
            if key == prev_key:
                collapsed += 1
                continue          # verbatim re-dump of the previous retirement
            prev_key = key
        yield ra, collapsed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("golden")
    ap.add_argument("rtl")
    ap.add_argument("--sys", action="store_true", help="compare cr0..cr4 too")
    ap.add_argument("--max", type=int, default=None, help="cap records compared")
    ap.add_argument("--dedup-golden", action="store_true",
                    help="collapse exact consecutive duplicate golden records "
                         "(qemu one-insn-per-tb re-dump artifact); see module doc")
    a = ap.parse_args()

    keys = tracefmt.func_compare_keys(x87=False, sys=a.sys)
    base_mask = tracefmt.EFLAGS_DEFAULT_MASK
    n = 0
    collapsed = 0
    with open(a.golden) as fa, open(a.rtl) as fc:
        ha, hc = fa.readline(), fc.readline()           # header lines
        if '"vtrace"' not in ha or '"vtrace"' not in hc:
            print("compare_stream: missing .vtrace header", file=sys.stderr)
            return 2
        # Compare in retire (stream) order. With --dedup-golden, the golden side
        # collapses exact consecutive re-dumps (so its `n` may run AHEAD of the RTL's
        # position) — alignment is positional, not by `n` value. We cross-check
        # ordering only when NOT deduping (the strict self-compare invariant).
        gold_iter = _golden_records(fa, a.dedup_golden)
        for lc in fc:
            if a.max is not None and n >= a.max:
                break
            try:
                ra, collapsed = next(gold_iter)
            except StopIteration:
                break                       # golden exhausted; RTL ran longer
            rc = json.loads(lc)
            na, nc = ra.get("n"), rc.get("n")
            if not a.dedup_golden and na != nc:
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
    tag = (f"; collapsed {collapsed} exact golden re-dump(s)"
           if a.dedup_golden else "")
    print(f"RESULT: EQUIVALENT ({n} records match, streamed; "
          f"eflags base mask {tracefmt.hx(base_mask,32)}{tag})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
