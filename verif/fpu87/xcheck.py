#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# =============================================================================
# xcheck.py — independent-oracle triangulation of a QEMU golden x87 trace.
#
# For one generated program, reads its <name>.cases.jsonl (each vector carries
# the result record index `rec` and the oracle-expected 80-bit result `exp`) and
# the QEMU golden .vtrace, then verifies that the QEMU golden's st0 at record
# `rec` equals the oracle's expected result. This proves the golden — which the
# RTL is diffed against by compare.py — is itself IEEE/x87-correct on the DATA
# result (SoftFloat <-> QEMU; the RTL <-> QEMU leg is compare.py).
#
# Exception-flag triangulation is intentionally NOT done here: the x87 status
# word is cumulative across the program (cleared only by the leading fninit), so
# per-op flags can't be read back from a single record. compare.py grades the
# full fstat RTL-vs-QEMU, so flag correctness is covered authoritatively there.
#
# Exit 0 if all checked vectors match (or none were checkable), 1 otherwise.
# Prints a JSON summary on stdout.
# =============================================================================
import argparse
import json
import sys


def load_trace_st0(path):
    """Return {n: int(st0)} for every record in a .vtrace (skips the header)."""
    st0 = {}
    with open(path) as f:
        first = True
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if first:
                first = False
                if "vtrace" in obj:        # header line
                    continue
            n = obj.get("n")
            if n is not None and "st0" in obj:
                st0[n] = int(obj["st0"], 16)
    return st0


def main(argv=None):
    p = argparse.ArgumentParser(description="oracle<->QEMU x87 triangulation")
    p.add_argument("--golden", required=True)
    p.add_argument("--cases", required=True)
    p.add_argument("--max-report", type=int, default=12)
    args = p.parse_args(argv)

    st0 = load_trace_st0(args.golden)
    checked = matched = 0
    missing = 0
    mismatches = []

    with open(args.cases) as f:
        for line in f:
            c = json.loads(line)
            if c.get("exp") is None:
                continue                    # SKIP op / no independent oracle
            rec = c["rec"]
            if rec not in st0:
                missing += 1                # trace truncated before this op
                continue
            checked += 1
            got = st0[rec]
            if got == c["exp"]:
                matched += 1
            elif len(mismatches) < 10000:
                mismatches.append(dict(op=c["op"], rc=c["rc"], a=c["a"], b=c.get("b"),
                                       rec=rec, exp="%020x" % c["exp"], got="%020x" % got))

    summary = dict(checked=checked, matched=matched,
                   mismatched=len(mismatches), missing=missing)
    print(json.dumps(summary))
    for m in mismatches[:args.max_report]:
        sys.stderr.write("  XCHK %s rc=%d a=%s b=%s  exp=%s got=%s\n"
                         % (m["op"], m["rc"], m["a"], m["b"], m["exp"], m["got"]))
    return 0 if not mismatches else 1


if __name__ == "__main__":
    sys.exit(main())
