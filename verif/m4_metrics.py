#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""m4_metrics.py — RTL-trace aggregate cycle metrics + 55-validate band check.

Used by verif/run-m4.sh. Computes, FROM THE RTL --cycle trace, the aggregate
metrics the M4 cycle micro-gate asserts against the documented P5 bands
(ventium-refs/.../scripts/55-validate-model.sh, docs/m4-pipeline-spec.md):

  depadd   : CPI 0.97-1.10  &  pairing% < 2
  indepadd : CPI 0.48-0.62  &  pairing% > 40
  agi      : AGI 1-cycle stalls FIRE (a meaningful fraction of insns stall)
  brloop   : mispredict% < 2
  brrandom : mispredict% > 20

EMERGENT-NOT-FAKED (docs/m4-pipeline-spec.md "The core principle"). Every cycle
NUMBER comes from the RTL pipeline's own cycle trace:
  * CPI       = RTL total cumulative cyc / retired instructions.
  * pairing%  = RTL records with paired==true / records carrying a pipe field.
  * AGI rate  = RTL instructions whose per-insn cost (cyc[n]-cyc[n-1]) >= 2.
                The agi kernel is pure lea/mov with no branches/microcode, so the
                ONLY source of a >1-cycle cost is the address-generation
                interlock — i.e. this IS the AGI-stall rate, measured from the
                RTL pipeline, not asserted.
  * mispredict% = RTL branch instances that incurred a pipeline-flush bubble
                (per-insn cost >= a misprediction-penalty threshold) over the
                number of branch instances.
The ONLY thing borrowed from the golden trace is per-instruction *identity*
(decode the golden's `bytes` to learn which records are conditional branches) so
the mispredict metric knows which records to inspect. The COSTS are 100% the
RTL's. We never reimplement the p5model cycle formula, so the agreement between
the RTL bands and the p5model bands is genuine evidence, not a tautology.

Output (stdout, ONE line, '|'-separated, consumed by run-m4.sh):
    VERDICT|CPI|PAIR|EXTRA|DETAIL
  VERDICT : PASS / FAIL
  CPI     : overall CPI, 3dp
  PAIR    : pairing%, 1dp
  EXTRA   : kernel-specific extra metric, e.g. "agi=83.1%" / "mispred=0.4%"
  DETAIL  : human band description incl. the band edges and pass/fail reason
Diagnostics go to stderr.
"""
from __future__ import annotations

import argparse
import os
import sys

# tracefmt.py is the shared trace parser in verif/diff/ (this helper lives one
# level up in verif/). Add verif/diff to the path so we reuse it, never
# duplicate it (docs/trace-format.md: tracefmt.py is the executable definition).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "diff"))
import tracefmt  # noqa: E402

# Optional capstone for decoding the golden `bytes` to a mnemonic (branch ident).
try:
    import capstone  # type: ignore
    _CS = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    _CS.detail = False
except Exception:  # pragma: no cover
    capstone = None
    _CS = None

# A mispredicted branch flushes the front of the pipe; the P5 penalty is 3 (U) /
# 4 (V) cycles, vs 0 bubble for a correctly-predicted branch (which then costs
# ~1, or 0 if paired). A per-instruction cost >= this threshold is therefore an
# unambiguous flush bubble. 3 is the smallest P5 mispredict penalty, so a branch
# costing >=3 cycles cannot be a correct prediction.
MISPREDICT_TH = 3

# AGI interlock inserts a 1-cycle stall, so an affected instruction costs >= 2.
AGI_TH = 2

# Branch mnemonics (conditional + the loop branch). capstone normalizes to these.
_COND_BRANCH_PREFIXES = (
    "j",     # jcc (je/jne/jz/jnz/jg/...) and jmp — jmp filtered out below
    "loop",  # loop/loope/loopne
)
_UNCOND = ("jmp",)


def _mnemonic(bytes_hex):
    if not bytes_hex or _CS is None:
        return None
    try:
        raw = bytes.fromhex(bytes_hex)
    except ValueError:
        return None
    for insn in _CS.disasm(raw, 0x0, count=1):
        return insn.mnemonic
    return None


def _is_cond_branch(mnem):
    if not mnem:
        return False
    m = mnem.lower()
    if m in _UNCOND:
        return False
    return any(m.startswith(p) for p in _COND_BRANCH_PREFIXES)


def _costs(records):
    """Per-instruction cost = cyc[n] - cyc[n-1] (cyc cumulative). cost[0]=cyc[0]
    is the warmup/first-instruction cost; we keep it but most metrics use the
    steady state, so leading transients don't dominate the long kernels."""
    costs = []
    prev = 0
    for r in records:
        c = int(r["cyc"])
        costs.append(c - prev)
        prev = c
    return costs


def compute(kernel, rtl_path, golden_path):
    rtl = tracefmt.read_trace(rtl_path)
    rr = rtl.records
    n = len(rr)
    if n == 0:
        raise ValueError("RTL trace has no records")

    total_cyc = int(rr[-1]["cyc"])
    cpi = total_cyc / n

    pipe_recs = sum(1 for r in rr if "pipe" in r)
    paired = sum(1 for r in rr if r.get("paired"))
    pairing_pct = (100.0 * paired / pipe_recs) if pipe_recs else 0.0

    costs = _costs(rr)

    # Align golden records (for branch identity via `bytes`) by index/n.
    gold = None
    try:
        gold = tracefmt.read_trace(golden_path)
    except Exception:
        gold = None
    gold_by_n = {}
    if gold is not None:
        for gr in gold.records:
            if "n" in gr:
                gold_by_n[int(gr["n"])] = gr

    kernel = kernel.replace("mb_", "")

    cpi_s = f"{cpi:.3f}"
    pair_s = f"{pairing_pct:.1f}"

    if kernel == "depadd":
        ok = (0.97 <= cpi <= 1.10) and (pairing_pct < 2.0)
        extra = "-"
        detail = (f"CPI in [0.97,1.10]? {0.97 <= cpi <= 1.10}; "
                  f"pairing<2%? {pairing_pct < 2.0}")
        return ("PASS" if ok else "FAIL"), cpi_s, pair_s, extra, detail

    if kernel == "indepadd":
        ok = (0.48 <= cpi <= 0.62) and (pairing_pct > 40.0)
        extra = "-"
        detail = (f"CPI in [0.48,0.62]? {0.48 <= cpi <= 0.62}; "
                  f"pairing>40%? {pairing_pct > 40.0}")
        return ("PASS" if ok else "FAIL"), cpi_s, pair_s, extra, detail

    if kernel == "agi":
        # AGI stalls FIRE: a meaningful fraction of insns cost >= 2 cycles. In
        # this pure lea/mov kernel the only >1-cycle source is the AGI interlock.
        # Exclude the single warmup record (index 0) so a cold first-fetch does
        # not masquerade as an AGI stall.
        stalls = sum(1 for c in costs[1:] if c >= AGI_TH)
        body = max(1, n - 1)
        rate = 100.0 * stalls / body
        ok = stalls > 0.2 * body           # 55-validate: agi_stalls > 0.2*insns
        extra = f"agi={rate:.1f}%"
        detail = (f"AGI stalls fire (>20% of insns cost>=2)? {ok} "
                  f"({stalls}/{body})")
        return ("PASS" if ok else "FAIL"), cpi_s, pair_s, extra, detail

    if kernel in ("brloop", "brrandom"):
        # Branch instances: RTL records whose golden-decoded mnemonic is a
        # conditional branch. mispredict = the branch instance incurred a flush
        # bubble (cost >= MISPREDICT_TH), OR the immediately-following record
        # (the redirect target) did — pipelines may attribute the bubble to
        # either side. Costs are entirely the RTL's.
        br_idx = []
        for i, r in enumerate(rr):
            gr = gold_by_n.get(int(r["n"]))
            mnem = _mnemonic(gr.get("bytes")) if gr else None
            if _is_cond_branch(mnem):
                br_idx.append(i)
        nbr = len(br_idx)
        if nbr == 0:
            # Could not identify branches via golden bytes (no capstone / no
            # bytes). Report and FAIL the band honestly rather than guessing.
            extra = "mispred=?"
            detail = ("could not identify branch instances from golden bytes "
                      "(capstone/bytes missing) — cannot measure mispredict%")
            return "FAIL", cpi_s, pair_s, extra, detail
        mis = 0
        for i in br_idx:
            c = costs[i]
            cn = costs[i + 1] if (i + 1) < n else 0
            if c >= MISPREDICT_TH or cn >= MISPREDICT_TH:
                mis += 1
        rate = 100.0 * mis / nbr
        extra = f"mispred={rate:.1f}%"
        if kernel == "brloop":
            ok = rate < 2.0
            detail = f"mispredict<2%? {ok} ({mis}/{nbr} branches)"
        else:
            ok = rate > 20.0
            detail = f"mispredict>20%? {ok} ({mis}/{nbr} branches)"
        return ("PASS" if ok else "FAIL"), cpi_s, pair_s, extra, detail

    if kernel == "agiloop":
        # INFO-only regression for the LOOPED-AGI fix (the suppressor that fired a
        # static AGI site only once per PC is removed). The body is a backward loop
        # `lea (esi),esi ; mov (esi),eax ; dec ecx ; jne` — the `mov` takes a
        # 1-cycle AGI stall EVERY iteration now (not just the first). We count the
        # load records (golden-decoded mnemonic not a branch) that cost >= 2 and
        # report the rate; if the fix regressed (one-stall-only) this collapses to
        # near 0%. Not a hard band (the hard AGI band is mb_agi); reported as INFO.
        load_stalls = 0
        loads = 0
        for i, r in enumerate(rr[1:], start=1):
            gr = gold_by_n.get(int(r["n"]))
            mnem = _mnemonic(gr.get("bytes")) if gr else None
            if mnem and mnem.startswith("mov"):
                loads += 1
                if costs[i] >= AGI_TH:
                    load_stalls += 1
        loads = max(1, loads)
        rate = 100.0 * load_stalls / loads
        extra = f"agi={rate:.1f}%"
        detail = (f"INFO: looped-AGI stall fires each iteration "
                  f"({load_stalls}/{loads} loads cost>=2; >50% expected, "
                  f"~0% if the one-stall-only regression returns)")
        return "INFO", cpi_s, pair_s, extra, detail

    if kernel == "faddchain":
        # FP cycle accuracy is M5 (not gated). Report CPI for information only.
        extra = "fp(M5)"
        detail = f"INFO only (FP cycle deferred to M5): CPI={cpi:.3f}"
        return "INFO", cpi_s, pair_s, extra, detail

    # Unknown kernel: report metrics, no band.
    return "INFO", cpi_s, pair_s, "-", f"no band defined for kernel '{kernel}'"


def main(argv=None):
    p = argparse.ArgumentParser(prog="m4_metrics.py")
    p.add_argument("--kernel", required=True)
    p.add_argument("--rtl", required=True)
    p.add_argument("--golden", required=True)
    a = p.parse_args(argv)
    try:
        verdict, cpi, pair, extra, detail = compute(a.kernel, a.rtl, a.golden)
    except Exception as e:  # pragma: no cover
        print(f"m4_metrics: {e}", file=sys.stderr)
        return 1
    # ONE line for run-m4.sh to parse. Diagnostics already on stderr.
    print(f"{verdict}|{cpi}|{pair}|{extra}|{detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
