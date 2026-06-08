#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""m5_metrics.py — RTL-trace aggregate cycle metrics + M5 band check.

Used by verif/run-m5.sh. M5 extends the M4 cycle gate with the two pieces M4
deferred and that the p5model oracle CAN differentially verify
(docs/m5-cycle-spec.md): **L1 cache-miss timing** and **x87/FP cycle accuracy**.

This module is the single metrics entry point for the M5 gate. It:

  * REUSES m4_metrics.compute() verbatim for the five integer kernels
    (depadd/indepadd/agi/brloop/brrandom) so the M4 55-validate bands are
    checked from the now-cache-aware RTL trace EXACTLY as in M4 — no
    re-derivation, no drift between the two gates.
  * ADDS the new M5 bands, every NUMBER computed from the RTL --cycle trace
    (emergent-not-faked, docs/m5-cycle-spec.md "Never fake a cycle match"):

      faddchain : dependent `fadd %st(1),%st` chain. fadd latency is 3, so a
                  fully-dependent chain runs at CPI ~ 3.0. GATED band (M5
                  promotes faddchain from INFO to gated): CPI in [2.7, 3.3].
                  This is emergent from the RTL FP latency pipe — if FP still
                  SERIALIZES (M4 behaviour) the CPI lands well outside the band.
      fpindep   : independent FP ops (fadd tput 1) pipeline, so CPI must be
                  BELOW the dependent-chain CPI (latency<->throughput contrast).
                  GATED relation band: fpindep CPI < faddchain CPI (with a small
                  margin) AND fpindep CPI lower than the fadd latency.
      dmiss     : strided D-cache-miss kernel. The misses must ELEVATE CPI
                  (dmiss CPI markedly above a cache-hit baseline) AND the RTL's
                  absolute total `cyc` must track the p5model golden within the
                  tightened M5 tolerance.
      imiss     : I-cache-miss kernel (code/loop straddling lines / > 8 KB).
                  Same two checks as dmiss.

For dmiss/imiss the band has TWO parts:
  (1) miss-driven CPI elevation  — emergent from the RTL cache hit/miss SM
      (CPI above a documented hit-baseline threshold);
  (2) abs-cyc tracking           — |RTL_total - golden_total| / golden_total
      within --abs-tol-pct (the tightened M5 tolerance), because once the RTL
      models the SAME caches/penalty as p5model the absolute cycle totals must
      converge, not just the ratios.

Output (stdout, ONE line, '|'-separated, consumed by run-m5.sh):
    VERDICT|CPI|PAIR|EXTRA|DETAIL
  VERDICT : PASS / FAIL / INFO
  CPI     : overall RTL CPI, 3dp
  PAIR    : pairing%, 1dp
  EXTRA   : kernel-specific extra metric (e.g. "absdiff=+2.1%" / "cpi<chain")
  DETAIL  : human band description incl. the band edges and pass/fail reason
Diagnostics go to stderr.

The faddchain reference CPI / fadd latency comes from docs/p5-timing-model.md
(fadd lat 3 / tput 1) — the SAME source the p5model oracle uses, so matching it
is the structural-fidelity claim, not a copied formula. The cycle oracle is an
ESTIMATE (docs/m5-cycle-spec.md "honest caveat"); two estimates need not be
bit-identical, so the abs-cyc tolerance is a documented band, not exact match.
"""
from __future__ import annotations

import argparse
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
# tracefmt.py is the shared trace parser in verif/diff/.
sys.path.insert(0, os.path.join(_HERE, "diff"))
# m4_metrics.py is one dir up (here); reuse its integer-kernel compute().
sys.path.insert(0, _HERE)

import tracefmt        # noqa: E402
import m4_metrics      # noqa: E402  (REUSED for the five integer kernels)

# ---------------------------------------------------------------------------
# M5 band constants. Latencies are the SAME ones the p5model oracle uses
# (docs/p5-timing-model.md): fadd/fsub lat 3 / tput 1.
# ---------------------------------------------------------------------------

# Dependent fadd chain: CPI converges to the fadd LATENCY (3). Band around 3.0
# per docs/m5-cycle-spec.md ("CPI ~ 3.0, band e.g. 2.7-3.3").
FADD_LAT = 3.0
FADDCHAIN_CPI_LO = 2.7
FADDCHAIN_CPI_HI = 3.3

# fpindep: independent fadds pipeline at tput 1, so CPI is well below the
# dependent-chain CPI. We require fpindep CPI to be below the faddchain CPI by a
# margin, AND below the fadd latency (it cannot exceed throughput-bound CPI).
# The margin guards against a degenerate "both ~3" pass if FP still serializes.
FPINDEP_MARGIN = 0.5     # fpindep must be at least this much below faddchain CPI
FPINDEP_CPI_MAX = 2.5    # and strictly below the latency (3) with headroom

# Miss kernels: a real miss-driven elevation pushes per-instruction cost well
# above the ~0.5-1.0 hit-path CPI. Threshold chosen conservatively so a kernel
# that genuinely streams through the miss penalty (imiss/dmiss=8) clears it,
# while a no-cache-timing RTL (every access a hit) stays below.
MISS_CPI_MIN = 1.30

# Integer DIVIDE occupancy band (review-response, m5-div-spec.md). DIV/IDIV are
# non-pipelined microcoded ops the p5model charges occ=17/25/41 (DIV r/m8/16/32)
# and 22/30/46 (IDIV). The RTL charges the modeled occupancy as a deferred
# penalty, so a divide-dominated kernel's CPI is far above the ~0.5-1.0 fast-path
# CPI. DIV_CPI_MIN gates "the occupancy is actually present" (a 1-clock native
# divide would land near ~3 incl. the loop, so 2.5 is a conservative floor that a
# missing-occupancy RTL fails); the abs-cyc-vs-p5model check pins the exact value.
DIV_CPI_MIN = 2.5
# expected p5model per-op occupancy by kernel (for the informational detail).
DIV_OCC = {"div8": 17, "div16": 25, "div32": 41, "idiv32": 46}

# Integer MULTIPLY occupancy band (review-response, m5-mul-spec.md). MUL/IMUL are
# non-pipelined microcoded ops the p5model charges occ=10 (all widths). The RTL
# charges the modeled occupancy as a deferred penalty, so a multiply-dominated
# kernel's CPI rises above the fast-path baseline. MUL_CPI_MIN gates "the
# occupancy is present" (a 1-cycle native multiply lands near ~1.5 incl. the
# loop; the occupancy lifts it to ~2.0), and the abs-cyc-vs-p5model check pins
# the exact occ=10.
MUL_CPI_MIN = 1.8
MUL_OCC = {"mul": 10, "imul2": 10}

# GAP1 FP/integer-overlap band (VEN_FP_OVERLAP, mb_fdivint). The kernel is an FDIV
# (occ 39) followed by 32 independent integer adds + a trailing FP producer. With
# the overlap modeled the adds retire IN the FDIV shadow -> CPI ~1.33; the
# SERIALIZED default (adds behind occ=39) lands at CPI ~1.73. The ceiling sits
# between them so a non-overlap RTL fails the "overlap present" half; the abs-cyc
# half pins the RTL to the fpovl=1 golden (a non-overlap RTL is ~+29% -> also FAIL).
FDIVINT_CPI_MAX = 1.50

# GAP2 free-FXCH band (VEN_FXCH_FREE, mb_fxch). 7 throughput-bound fld1 producers
# each followed by an FXCH. With the FXCH folded into the preceding fld's commit
# (occ 0) CPI ~0.98; the DEFAULT (each FXCH a full clock, no latency gap to hide in)
# lands at CPI ~1.29. The ceiling sits between them so a non-folding RTL fails the
# "FXCH free" half; the abs-cyc half pins the RTL to the fxchfree=1 golden.
FXCH_CPI_MAX = 1.10

# AP-500 fast-path PAIRING-coverage band (review-response, fastpath-coverage-spec
# .md). A converted form must actually PAIR (issue into the V pipe) where it
# previously serialized on the slow FSM. The kernel alternates a converted U-form
# with an independent pairable V partner, so ~50% of records are paired when the
# coverage works and ~0% when the form falls to the slow FSM. PAIR_MIN gates "the
# form pairs"; abs-cyc-vs-p5model pins that the RTL converges to the oracle (which
# also pairs these forms).
PAIR_MIN = 40.0

# Default tightened abs-cyc tolerance (overridable via --abs-tol-pct from
# run-m5.sh, which owns the documented M5_TOL_PCT choice).
DEFAULT_ABS_TOL_PCT = 10.0


def _total_cyc(trace):
    """Cumulative cyc of the last record (the trace's total core clocks)."""
    recs = trace.records
    if not recs:
        return 0
    return int(recs[-1].get("cyc", 0))


def _basic(rtl):
    """(n, total_cyc, cpi, pairing%) from an RTL --cycle trace."""
    rr = rtl.records
    n = len(rr)
    if n == 0:
        raise ValueError("RTL trace has no records")
    total = int(rr[-1].get("cyc", 0))
    cpi = total / n
    pipe_recs = sum(1 for r in rr if "pipe" in r)
    paired = sum(1 for r in rr if r.get("paired"))
    pairing = (100.0 * paired / pipe_recs) if pipe_recs else 0.0
    return n, total, cpi, pairing


def _abs_diff_pct(rtl_total, gold_total):
    """Signed % difference of RTL total vs golden total (RTL relative to gold)."""
    if gold_total == 0:
        return 0.0 if rtl_total == 0 else 100.0
    return 100.0 * (rtl_total - gold_total) / gold_total


def compute(kernel, rtl_path, golden_path, abs_tol_pct=DEFAULT_ABS_TOL_PCT):
    short = kernel.replace("mb_", "")

    # --- Integer kernels: delegate verbatim to m4_metrics (no re-derivation) ---
    if short in ("depadd", "indepadd", "agi", "brloop", "brrandom", "agiloop"):
        verdict, cpi_s, pair_s, extra, detail = m4_metrics.compute(
            kernel, rtl_path, golden_path)
        # Annotate with abs-cyc tracking for the M5 "tightened tolerance" report.
        # This does NOT change the M4 band verdict (the band is the verdict);
        # it adds the absolute-cycle figure the M5 spec item (5) asks us to
        # report under the tightened tolerance.
        try:
            rtl = tracefmt.read_trace(rtl_path)
            gold = tracefmt.read_trace(golden_path)
            rtl_total = _total_cyc(rtl)
            gold_total = _total_cyc(gold)
            d = _abs_diff_pct(rtl_total, gold_total)
            within = abs(d) <= abs_tol_pct
            extra = f"abscyc={d:+.2f}%"
            detail = (f"{detail}; abs-cyc {d:+.2f}% vs golden "
                      f"(<= {abs_tol_pct:.0f}%? {within})")
        except Exception as e:  # pragma: no cover
            print(f"m5_metrics: abs-cyc annotate failed: {e}", file=sys.stderr)
        return verdict, cpi_s, pair_s, extra, detail

    # --- New M5 kernels --------------------------------------------------------
    rtl = tracefmt.read_trace(rtl_path)
    n, total, cpi, pairing = _basic(rtl)
    cpi_s = f"{cpi:.3f}"
    pair_s = f"{pairing:.1f}"

    if short == "faddchain":
        # GATED in M5 (was INFO in M4): dependent fadd chain -> CPI ~ fadd lat 3.
        ok = FADDCHAIN_CPI_LO <= cpi <= FADDCHAIN_CPI_HI
        extra = f"cpi~lat{FADD_LAT:.0f}"
        detail = (f"dependent fadd chain CPI in "
                  f"[{FADDCHAIN_CPI_LO},{FADDCHAIN_CPI_HI}]? {ok} "
                  f"(CPI={cpi:.3f}, fadd lat={FADD_LAT:.0f}); emergent from RTL "
                  f"FP latency pipe — if FP serializes this misses")
        return ("PASS" if ok else "FAIL"), cpi_s, pair_s, extra, detail

    if short == "fpindep":
        # GATED relation: independent FP pipelines (tput 1) so CPI must be BELOW
        # the dependent faddchain CPI. We need the faddchain CPI to compare to;
        # the run-m5 harness passes it via the env so we don't re-run it here.
        chain_cpi = None
        env = os.environ.get("M5_FADDCHAIN_CPI")
        if env:
            try:
                chain_cpi = float(env)
            except ValueError:
                chain_cpi = None
        below_lat = cpi < FPINDEP_CPI_MAX
        if chain_cpi is not None:
            below_chain = cpi < (chain_cpi - FPINDEP_MARGIN)
            ok = below_chain and below_lat
            extra = f"cpi<chain"
            detail = (f"fpindep CPI {cpi:.3f} < faddchain CPI {chain_cpi:.3f}"
                      f"-{FPINDEP_MARGIN} ({below_chain}) AND < "
                      f"{FPINDEP_CPI_MAX} ({below_lat})? {ok} "
                      f"(throughput<->latency: independent FP must pipeline)")
        else:
            # No faddchain CPI available: fall back to the absolute throughput
            # ceiling only, and SAY SO honestly (we cannot prove the relation).
            ok = below_lat
            extra = f"cpi<{FPINDEP_CPI_MAX:.1f}"
            detail = (f"fpindep CPI {cpi:.3f} < {FPINDEP_CPI_MAX} ({below_lat})? "
                      f"{ok} (NOTE: faddchain CPI unavailable — relation "
                      f"check skipped; set M5_FADDCHAIN_CPI to enable)")
        return ("PASS" if ok else "FAIL"), cpi_s, pair_s, extra, detail

    if short in ("dmiss", "imiss"):
        # TWO-part band: (1) miss-driven CPI elevation; (2) abs-cyc tracks the
        # p5model golden within the tightened tolerance.
        try:
            gold = tracefmt.read_trace(golden_path)
            gold_total = _total_cyc(gold)
        except Exception as e:
            return ("FAIL", cpi_s, pair_s, "abscyc=?",
                    f"golden trace unreadable ({e}) — cannot check abs-cyc")
        d = _abs_diff_pct(total, gold_total)
        elevated = cpi >= MISS_CPI_MIN
        tracked = abs(d) <= abs_tol_pct
        ok = elevated and tracked
        extra = f"abscyc={d:+.2f}%"
        detail = (f"miss-driven CPI elevation (CPI {cpi:.3f} >= "
                  f"{MISS_CPI_MIN})? {elevated}; abs-cyc {d:+.2f}% vs golden "
                  f"(<= {abs_tol_pct:.0f}%)? {tracked}; both? {ok}")
        return ("PASS" if ok else "FAIL"), cpi_s, pair_s, extra, detail

    if short in ("div8", "div16", "div32", "idiv32"):
        # TWO-part band (mirrors dmiss/imiss): (1) the divide occupancy is present
        # (CPI elevated well above the fast-path baseline); (2) abs-cyc tracks the
        # p5model golden within tolerance — the golden encodes occ*n_div, so this
        # pins the exact modeled occupancy (17/25/41 DIV, 46 IDIV).
        try:
            gold = tracefmt.read_trace(golden_path)
            gold_total = _total_cyc(gold)
        except Exception as e:
            return ("FAIL", cpi_s, pair_s, "abscyc=?",
                    f"golden trace unreadable ({e}) — cannot check abs-cyc")
        d = _abs_diff_pct(total, gold_total)
        occ = DIV_OCC.get(short, 0)
        elevated = cpi >= DIV_CPI_MIN
        tracked = abs(d) <= abs_tol_pct
        ok = elevated and tracked
        extra = f"abscyc={d:+.2f}%"
        detail = (f"divide-occupancy present (CPI {cpi:.3f} >= {DIV_CPI_MIN})? "
                  f"{elevated}; abs-cyc {d:+.2f}% vs p5model (occ~{occ}) "
                  f"(<= {abs_tol_pct:.0f}%)? {tracked}; both? {ok}")
        return ("PASS" if ok else "FAIL"), cpi_s, pair_s, extra, detail

    if short in ("mul", "imul2"):
        # TWO-part band (mirrors div): (1) multiply occupancy present (CPI above
        # the fast-path baseline); (2) abs-cyc tracks the p5model golden within
        # tolerance — pins the modeled occ=10.
        try:
            gold = tracefmt.read_trace(golden_path)
            gold_total = _total_cyc(gold)
        except Exception as e:
            return ("FAIL", cpi_s, pair_s, "abscyc=?",
                    f"golden trace unreadable ({e}) — cannot check abs-cyc")
        d = _abs_diff_pct(total, gold_total)
        occ = MUL_OCC.get(short, 0)
        elevated = cpi >= MUL_CPI_MIN
        tracked = abs(d) <= abs_tol_pct
        ok = elevated and tracked
        extra = f"abscyc={d:+.2f}%"
        detail = (f"multiply-occupancy present (CPI {cpi:.3f} >= {MUL_CPI_MIN})? "
                  f"{elevated}; abs-cyc {d:+.2f}% vs p5model (occ~{occ}) "
                  f"(<= {abs_tol_pct:.0f}%)? {tracked}; both? {ok}")
        return ("PASS" if ok else "FAIL"), cpi_s, pair_s, extra, detail

    if short in ("accimm", "rmimm", "sh1", "nearbr"):
        # PAIRING-coverage band: (1) the converted form pairs (pairing% above the
        # serialized baseline); (2) abs-cyc tracks the p5model golden (which pairs
        # these forms) within tolerance.
        try:
            gold = tracefmt.read_trace(golden_path)
            gold_total = _total_cyc(gold)
        except Exception as e:
            return ("FAIL", cpi_s, pair_s, "abscyc=?",
                    f"golden trace unreadable ({e}) — cannot check abs-cyc")
        d = _abs_diff_pct(total, gold_total)
        paired_ok = pairing >= PAIR_MIN
        tracked = abs(d) <= abs_tol_pct
        ok = paired_ok and tracked
        extra = f"pair={pairing:.0f}%"
        detail = (f"fast-path pairing present (pairing% {pairing:.1f} >= "
                  f"{PAIR_MIN})? {paired_ok}; abs-cyc {d:+.2f}% vs p5model "
                  f"(<= {abs_tol_pct:.0f}%)? {tracked}; both? {ok}")
        return ("PASS" if ok else "FAIL"), cpi_s, pair_s, extra, detail

    if short == "fdivint":
        # GAP1 TWO-part band (VEN_FP_OVERLAP): (1) the FDIV/integer OVERLAP is present
        # — CPI below the serialized-default ceiling (a non-overlap RTL serializes the
        # 32 adds behind the FDIV occ=39 -> CPI ~1.73 > the ceiling); (2) abs-cyc
        # tracks the fpovl=1 split-timeline golden within tolerance (a non-overlap RTL
        # is ~+29% -> also fails). Both pin the overlap quantitatively.
        try:
            gold = tracefmt.read_trace(golden_path)
            gold_total = _total_cyc(gold)
        except Exception as e:
            return ("FAIL", cpi_s, pair_s, "abscyc=?",
                    f"golden trace unreadable ({e}) — cannot check abs-cyc")
        d = _abs_diff_pct(total, gold_total)
        overlapped = cpi <= FDIVINT_CPI_MAX
        tracked = abs(d) <= abs_tol_pct
        ok = overlapped and tracked
        extra = f"abscyc={d:+.2f}%"
        detail = (f"FDIV/int overlap present (CPI {cpi:.3f} <= {FDIVINT_CPI_MAX}, "
                  f"vs ~1.73 serialized)? {overlapped}; abs-cyc {d:+.2f}% vs fpovl=1 "
                  f"p5model (<= {abs_tol_pct:.0f}%)? {tracked}; both? {ok}")
        return ("PASS" if ok else "FAIL"), cpi_s, pair_s, extra, detail

    if short == "fxch":
        # GAP2 TWO-part band (VEN_FXCH_FREE): (1) the FXCH is FREE — CPI below the
        # serialized-default ceiling (a non-folding RTL charges each FXCH a clock ->
        # CPI ~1.29 > ceiling); (2) abs-cyc tracks the fxchfree=1 golden within tol.
        try:
            gold = tracefmt.read_trace(golden_path)
            gold_total = _total_cyc(gold)
        except Exception as e:
            return ("FAIL", cpi_s, pair_s, "abscyc=?",
                    f"golden trace unreadable ({e}) — cannot check abs-cyc")
        d = _abs_diff_pct(total, gold_total)
        freed = cpi <= FXCH_CPI_MAX
        tracked = abs(d) <= abs_tol_pct
        ok = freed and tracked
        extra = f"abscyc={d:+.2f}%"
        detail = (f"FXCH free (CPI {cpi:.3f} <= {FXCH_CPI_MAX}, vs ~1.29 serialized)? "
                  f"{freed}; abs-cyc {d:+.2f}% vs fxchfree=1 p5model (<= {abs_tol_pct:.0f}%)? "
                  f"{tracked}; both? {ok}")
        return ("PASS" if ok else "FAIL"), cpi_s, pair_s, extra, detail

    # Unknown kernel: report metrics, no band (INFO).
    return ("INFO", cpi_s, pair_s, "-",
            f"no M5 band defined for kernel '{short}' (CPI={cpi:.3f})")


def main(argv=None):
    p = argparse.ArgumentParser(prog="m5_metrics.py")
    p.add_argument("--kernel", required=True)
    p.add_argument("--rtl", required=True)
    p.add_argument("--golden", required=True)
    p.add_argument("--abs-tol-pct", type=float, default=DEFAULT_ABS_TOL_PCT,
                   help="tightened M5 abs-cyc tolerance (run-m5.sh owns the "
                        "documented value)")
    a = p.parse_args(argv)
    try:
        verdict, cpi, pair, extra, detail = compute(
            a.kernel, a.rtl, a.golden, abs_tol_pct=a.abs_tol_pct)
    except Exception as e:  # pragma: no cover
        print(f"m5_metrics: {e}", file=sys.stderr)
        return 1
    print(f"{verdict}|{cpi}|{pair}|{extra}|{detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
