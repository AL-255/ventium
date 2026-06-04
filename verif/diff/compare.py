#!/usr/bin/env python3
"""Ventium differential trace comparator (Consumer) — docs/trace-format.md §3.

Reads two `.vtrace` files and diffs them, in one of two modes:

  * func  — Producer A = QEMU gdbstub (golden) vs Producer C = RTL.
            Compares architectural state per the field order returned by
            tracefmt.func_compare_keys(); EFLAGS under an architectural mask
            (minus per-instruction undefined flags).  Reports the FIRST
            divergence as {n, pc, field, expected (A), got (C)} and stops,
            or with --all lists up to --max-report divergences.

  * cycle — Producer B = QEMU plugin (golden) vs Producer C = RTL.
            Aligns by `n`, sanity-checks pc, derives per-instruction cost
            cyc[n]-cyc[n-1], compares totals within --tol-pct, and prints an
            aggregate summary (CPI, pairing%, pipe mix, out-of-tolerance count).

Exit status (docs/trace-format.md §3 "Exit status"):
  0 = traces equivalent under the selected mode/tolerance
  1 = divergence found
  2 = malformed input / length mismatch the modes don't allow

The shared format parser is tracefmt.py (imported, never duplicated). See
PLAN.md §4.3 (the differential comparator).
"""
from __future__ import annotations

import argparse
import os
import sys

# tracefmt.py lives in the same directory; make sure we can import it whatever
# the caller's CWD is.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tracefmt  # noqa: E402  (path set above)


# --- optional capstone (for EFLAGS undefined-flag masking via 'bytes') -------
# The comparator can decode a record's `bytes` field to recover the mnemonic so
# that EFLAGS bits left architecturally undefined by that instruction are
# excluded from the compare (docs/trace-format.md §3 "EFLAGS masking").  When
# capstone or `bytes` is unavailable we simply fall back to the full mask.
try:
    import capstone  # type: ignore

    _CS = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    _CS.detail = False
except Exception:  # pragma: no cover - capstone is present in this env
    capstone = None
    _CS = None


def _mnemonic_from_bytes(bytes_hex: str | None) -> str | None:
    """Decode the leading instruction in `bytes` (lowercase hex, no 0x) to a
    mnemonic.  Returns None if we can't (no capstone, no bytes, decode fail)."""
    if not bytes_hex or _CS is None:
        return None
    try:
        raw = bytes.fromhex(bytes_hex)
    except ValueError:
        return None
    for insn in _CS.disasm(raw, 0x0, count=1):
        return insn.mnemonic
    return None


# --- header validation -------------------------------------------------------
def _vtrace_ok(hdr: dict) -> bool:
    return isinstance(hdr, dict) and hdr.get("vtrace") == tracefmt.VERSION


# Per-mode expected golden / RTL producer names, for a friendly warning only.
_EXPECTED_PRODUCERS = {
    "func": ("qemu-gdbstub", "rtl"),
    "cycle": ("qemu-plugin", "rtl"),
}


def validate_headers(mode: str, a: tracefmt.Trace, c: tracefmt.Trace,
                     warn) -> tuple[bool, bool, bool]:
    """Validate both headers against `mode`.

    Returns (ok, x87_both, sys_both):
      ok        -- True if headers are usable (else caller should exit 2)
      x87_both  -- True iff *both* func headers declare x87 (only meaningful
                   for func mode); when exactly one declares x87 we warn and
                   compare only the common fields.
      sys_both  -- True iff *both* func headers declare sys:true (M2S). When set,
                   the system control registers (cr0/cr2/cr3/cr4) join the compare
                   and the segment-hidden fields are diffed only where present in
                   BOTH traces (see compare_func). When exactly one declares sys
                   we warn and fall back to the user-mode integer/seg compare.
    """
    if not _vtrace_ok(a.hdr):
        warn(f"A: not a vtrace v{tracefmt.VERSION} header: {a.hdr!r}")
        return False, False, False
    if not _vtrace_ok(c.hdr):
        warn(f"C: not a vtrace v{tracefmt.VERSION} header: {c.hdr!r}")
        return False, False, False

    # Modes must match the requested --mode (this is a hard error: comparing a
    # func trace as cycle is meaningless and counts as malformed input).
    if a.mode != mode:
        warn(f"A mode {a.mode!r} != requested --mode {mode!r}")
        return False, False, False
    if c.mode != mode:
        warn(f"C mode {c.mode!r} != requested --mode {mode!r}")
        return False, False, False

    # Producer mismatch is only a soft warning (spec: "warn (not fail)").
    exp_a, exp_c = _EXPECTED_PRODUCERS[mode]
    pa, pc = a.hdr.get("producer"), c.hdr.get("producer")
    if pa != exp_a:
        warn(f"A producer {pa!r} (expected golden {exp_a!r} for {mode} mode)")
    if pc != exp_c:
        warn(f"C producer {pc!r} (expected {exp_c!r} for {mode} mode)")

    # x87: compare x87 fields only when BOTH say x87. If exactly one does, note
    # it and fall back to the common integer/seg fields.
    x87_both = bool(a.x87 and c.x87)
    if mode == "func" and (a.x87 != c.x87):
        warn(f"x87 header mismatch (A x87={a.x87}, C x87={c.x87}); "
             "comparing common integer/seg fields only")

    # sys (M2S): compare the system fields only when BOTH say sys. If exactly one
    # does, warn and fall back to the user-mode integer/seg compare (so a user
    # trace vs a sys trace is never silently wrong). Only meaningful in func mode.
    sys_both = bool(a.sys and c.sys)
    if mode == "func" and (a.sys != c.sys):
        warn(f"sys header mismatch (A sys={a.sys}, C sys={c.sys}); "
             "comparing common user-mode integer/seg fields only")
    return True, x87_both, sys_both


# --- functional-mode compare -------------------------------------------------
def _eflags_equal(a_hex: str, c_hex: str, base_mask: int, mnemonic: str | None):
    """Return (equal, effective_mask). Compares (a ^ c) & mask == 0 with the
    per-instruction undefined flags removed from the mask."""
    undef = tracefmt.eflags_undefined_mask(mnemonic)
    mask = base_mask & ~undef
    a = tracefmt.parse_hex(a_hex)
    c = tracefmt.parse_hex(c_hex)
    return (((a ^ c) & mask) == 0), mask


def _sys_keys_intersection(keys: list, ra: list, rc: list) -> list:
    """For a sys (M2S) compare, drop any *system* field absent from EITHER trace.

    The control-register block (cr0/cr2/cr3/cr4) is always present in both sys
    producers and stays in `keys`.  The segment-hidden descriptor fields
    (<seg>_base/_limit/_attr) are RESERVED and optional: the gdbstub golden emits
    only a subset (e.g. ss_base..gs_base) and the RTL producer may emit a
    different subset, so per docs/trace-format.md §2.4 we INTERSECT — a hidden
    field a producer legitimately omits must never force a miss.  We append the
    hidden fields that appear in *both* traces (in canonical SYS_SEG_HIDDEN order)
    and leave the user-mode + CRx keys untouched.

    Only the system-specific fields are intersected: the user-mode fields (pc,
    GPRs, eflags, selectors, x87, CRx) remain mandatory — their absence on one
    side is still a real divergence, exactly as in user-mode compare.
    """
    # Hidden fields present in EVERY record of BOTH traces (a producer that emits
    # a hidden field must emit it consistently; "present in both" = present in the
    # first record of each, which the well-formedness check guarantees uniform).
    def _has(recs, k):
        return bool(recs) and k in recs[0]
    extra = [k for k in tracefmt.SYS_SEG_HIDDEN
             if _has(ra, k) and _has(rc, k)]
    return keys + extra


def compare_func(a: tracefmt.Trace, c: tracefmt.Trace, x87_both: bool,
                 eflags_mask: int, show_all: bool, max_report: int,
                 out, sys_both: bool = False) -> int:
    """Functional-mode compare. Returns an exit code (0/1/2).

    When `sys_both` is set (both headers sys:true, M2S), the system control
    registers (cr0/cr2/cr3/cr4) are compared alongside the user-mode fields, and
    any segment-hidden descriptor field present in BOTH traces is compared too
    (reserved fields a producer omits are intersected out, never a miss).
    """
    keys = tracefmt.func_compare_keys(x87_both, sys=sys_both)
    ra, rc = a.records, c.records
    if sys_both:
        keys = _sys_keys_intersection(keys, ra, rc)
    n_common = min(len(ra), len(rc))

    divergences = []  # list of (n, pc, field, expected, got)

    for i in range(n_common):
        rec_a, rec_c = ra[i], rc[i]
        # Align by 'n': the records are in retire order, but cross-check the
        # sequence number so a dropped/duplicated record is caught explicitly.
        na, nc = rec_a.get("n"), rec_c.get("n")
        if na != nc:
            divergences.append((na, rec_a.get("pc", "?"), "n",
                                str(na), str(nc)))
            if not show_all:
                break
            continue

        pc_a = rec_a.get("pc", "?")
        # Recover mnemonic for EFLAGS undefined-flag masking. Prefer the golden
        # (A) bytes; fall back to C's.
        mnem = _mnemonic_from_bytes(rec_a.get("bytes")) \
            or _mnemonic_from_bytes(rec_c.get("bytes"))

        rec_div = False
        for field in keys:
            va = rec_a.get(field)
            vc = rec_c.get(field)
            # A field defined in the spec but absent from one side is itself a
            # divergence (the producers disagree on what state exists).
            if va is None or vc is None:
                if va is None and vc is None:
                    continue  # neither carries it -> nothing to compare
                divergences.append((na, pc_a, field,
                                    "<absent>" if va is None else va,
                                    "<absent>" if vc is None else vc))
                rec_div = True
                if not show_all:
                    break
                continue

            if field == "eflags":
                eq, eff = _eflags_equal(va, vc, eflags_mask, mnem)
                if not eq:
                    note = f"eflags(mask={tracefmt.hx(eff, 32)})"
                    divergences.append((na, pc_a, note, va, vc))
                    rec_div = True
                    if not show_all:
                        break
            else:
                if va != vc:
                    divergences.append((na, pc_a, field, va, vc))
                    rec_div = True
                    if not show_all:
                        break

        if rec_div and not show_all:
            break
        if show_all and len(divergences) >= max_report:
            break

    # Length mismatch is reported clearly but, per spec, is itself a divergence
    # (exit 1) not malformed input — the headers parsed fine.
    len_mismatch = len(ra) != len(rc)

    # --- report ---
    print("=== Ventium functional diff (A=golden QEMU, C=RTL) ===", file=out)
    print(f"A records: {len(ra)}   C records: {len(rc)}   "
          f"compared: {n_common}", file=out)
    print(f"eflags base mask: {tracefmt.hx(eflags_mask, 32)}   "
          f"x87 compared: {x87_both}   sys compared: {sys_both}", file=out)

    if not divergences and not len_mismatch:
        print(f"RESULT: EQUIVALENT ({n_common} records match)", file=out)
        return 0

    if divergences:
        shown = divergences if show_all else divergences[:1]
        print(f"RESULT: DIVERGENT ({len(divergences)} field divergence(s)"
              f"{' — first shown' if not show_all else ''})", file=out)
        for (n, pc, field, exp, got) in shown:
            print(f"  n={n} pc={pc} field={field}: "
                  f"expected(A)={exp} got(C)={got}", file=out)
    else:
        print("RESULT: DIVERGENT (length mismatch only)", file=out)

    if len_mismatch:
        longer = "A" if len(ra) > len(rc) else "C"
        print(f"  LENGTH MISMATCH: A has {len(ra)}, C has {len(rc)} records "
              f"({longer} is longer); compared first {n_common}.", file=out)

    return 1


# --- cycle-mode compare ------------------------------------------------------
def _pct_diff(a: float, b: float) -> float:
    """Percentage difference of b relative to a (golden). 0/0 -> 0."""
    if a == 0:
        return 0.0 if b == 0 else float("inf")
    return (b - a) / a * 100.0


def compare_cycle(a: tracefmt.Trace, c: tracefmt.Trace, tol_pct: float,
                  show_all: bool, max_report: int, out) -> int:
    """Cycle-mode compare. Returns an exit code (0/1/2)."""
    ra, rc = a.records, c.records
    n_common = min(len(ra), len(rc))
    len_mismatch = len(ra) != len(rc)

    pc_mismatches = []     # (n, pc_a, pc_c) — sanity check, reported not fatal
    oot = []               # (n, pc, cost_a, cost_c, pct) out-of-tolerance
    n_seq_mismatch = 0

    prev_cyc_a = 0
    prev_cyc_c = 0
    paired_count = 0
    pipe_mix = {}          # pipe symbol -> count (from C / RTL records)
    pipe_recs = 0          # records that actually carry a 'pipe' field

    for i in range(n_common):
        rec_a, rec_c = ra[i], rc[i]
        na, nc = rec_a.get("n"), rec_c.get("n")
        if na != nc:
            n_seq_mismatch += 1

        pc_a = rec_a.get("pc")
        pc_c = rec_c.get("pc")
        if pc_a is not None and pc_c is not None and pc_a != pc_c:
            pc_mismatches.append((na, pc_a, pc_c))

        cyc_a = rec_a.get("cyc")
        cyc_c = rec_c.get("cyc")
        # cumulative cyc must be present for a cycle trace.
        if cyc_a is None or cyc_c is None:
            print("ERROR: cycle record missing 'cyc' field at "
                  f"n={na} (A={cyc_a}, C={cyc_c})", file=out)
            return 2

        cost_a = cyc_a - prev_cyc_a
        cost_c = cyc_c - prev_cyc_c
        prev_cyc_a, prev_cyc_c = cyc_a, cyc_c

        pct = _pct_diff(cost_a, cost_c)
        # tol_pct == 0 means exact match required.
        if abs(pct) > tol_pct:
            oot.append((na, pc_a, cost_a, cost_c, pct))

        # pipe mix / pairing are gathered from whichever records carry them
        # (the cycle producer B + RTL C). We report C's (RTL) view since C is
        # the device under test; B's view is the golden reference.
        if "pipe" in rec_c:
            pipe_recs += 1
            sym = rec_c["pipe"]
            pipe_mix[sym] = pipe_mix.get(sym, 0) + 1
        if rec_c.get("paired"):
            paired_count += 1

    total_a = ra[n_common - 1].get("cyc", 0) if n_common else 0
    total_c = rc[n_common - 1].get("cyc", 0) if n_common else 0
    total_pct = _pct_diff(total_a, total_c)

    # CPI uses the device-under-test (C) cycles over instruction count.
    cpi_a = (total_a / n_common) if n_common else 0.0
    cpi_c = (total_c / n_common) if n_common else 0.0
    pairing_pct = (100.0 * paired_count / pipe_recs) if pipe_recs else 0.0

    # --- aggregate summary ---
    print("=== Ventium cycle diff (A=golden p5model/QEMU, C=RTL) ===",
          file=out)
    print(f"A records: {len(ra)}   C records: {len(rc)}   "
          f"compared: {n_common}", file=out)
    print(f"total cycles: A={total_a}  C={total_c}  "
          f"diff={total_pct:+.2f}%   (tol={tol_pct:.2f}%)", file=out)
    print(f"overall CPI: A={cpi_a:.3f}  C={cpi_c:.3f}", file=out)
    if pipe_recs:
        mix = "  ".join(f"{k}={v}" for k, v in sorted(pipe_mix.items()))
        print(f"pipe mix (C): {mix}   pairing%={pairing_pct:.1f} "
              f"({paired_count}/{pipe_recs})", file=out)
    else:
        print("pipe mix (C): <no pipe/paired fields in C records>", file=out)
    print(f"out-of-tolerance instructions: {len(oot)}", file=out)
    if n_seq_mismatch:
        print(f"NOTE: {n_seq_mismatch} record(s) had mismatched 'n' "
              "(retire-order skew)", file=out)
    if pc_mismatches:
        print(f"NOTE: {len(pc_mismatches)} pc mismatch(es) "
              "(control-flow divergence) — showing up to "
              f"{min(len(pc_mismatches), max_report)}:", file=out)
        for (n, pa, pcc) in pc_mismatches[:max_report]:
            print(f"  n={n} pc A={pa} C={pcc}", file=out)

    # --- verdict ---
    # A pc mismatch means the two runs executed different instructions: that is
    # a hard divergence regardless of cycle tolerance.
    if pc_mismatches or n_seq_mismatch:
        print("RESULT: DIVERGENT (control-flow / retire-order mismatch)",
              file=out)
        return 1

    if oot:
        shown = oot if show_all else oot[:1]
        print(f"RESULT: DIVERGENT ({len(oot)} out-of-tolerance"
              f"{', first shown' if not show_all else ''})", file=out)
        for (n, pc, ca, cc, pct) in shown[:max_report]:
            print(f"  n={n} pc={pc} cost A={ca} C={cc} ({pct:+.2f}% > "
                  f"{tol_pct:.2f}%)", file=out)
        if len_mismatch:
            print(f"  LENGTH MISMATCH: A has {len(ra)}, C has {len(rc)}.",
                  file=out)
        return 1

    if len_mismatch:
        print(f"RESULT: DIVERGENT (length mismatch: A={len(ra)} C={len(rc)})",
              file=out)
        return 1

    print(f"RESULT: EQUIVALENT (total cycles within {tol_pct:.2f}%)", file=out)
    return 0


# --- CLI ---------------------------------------------------------------------
def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        prog="compare.py",
        description="Ventium differential trace comparator "
                    "(docs/trace-format.md §3).")
    p.add_argument("--mode", required=True, choices=("func", "cycle"),
                   help="func: A=QEMU gdbstub vs C=RTL; "
                        "cycle: A=QEMU plugin vs C=RTL")
    p.add_argument("--all", action="store_true",
                   help="list up to --max-report divergences instead of "
                        "stopping at the first")
    p.add_argument("--tol-pct", type=float, default=0.0,
                   help="cycle mode: per-instruction tolerance band in %% "
                        "(default 0.0 = exact)")
    p.add_argument("--eflags-mask", type=lambda s: int(s, 0), default=None,
                   help="func mode: override EFLAGS compare mask "
                        f"(default {tracefmt.hx(tracefmt.EFLAGS_DEFAULT_MASK, 32)})")
    p.add_argument("--max-report", type=int, default=20,
                   help="with --all, max divergences to print (default 20)")
    p.add_argument("a", metavar="A.vtrace", help="golden trace (QEMU)")
    p.add_argument("c", metavar="C.vtrace", help="device-under-test (RTL)")
    args = p.parse_args(argv)

    def warn(msg):
        print(f"WARN: {msg}", file=sys.stderr)

    # --- read + parse (malformed -> exit 2) ---
    try:
        a = tracefmt.read_trace(args.a)
        c = tracefmt.read_trace(args.c)
    except (OSError, ValueError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    ok, x87_both, sys_both = validate_headers(args.mode, a, c, warn)
    if not ok:
        print("ERROR: header validation failed (see warnings) -> "
              "malformed/incompatible input", file=sys.stderr)
        return 2

    eflags_mask = (args.eflags_mask if args.eflags_mask is not None
                   else tracefmt.EFLAGS_DEFAULT_MASK)

    if args.mode == "func":
        return compare_func(a, c, x87_both, eflags_mask, args.all,
                            args.max_report, sys.stdout, sys_both=sys_both)
    else:
        return compare_cycle(a, c, args.tol_pct, args.all,
                             args.max_report, sys.stdout)


if __name__ == "__main__":
    sys.exit(main())
