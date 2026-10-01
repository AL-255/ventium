#!/usr/bin/env python3
"""Grade canonical +ven_faultlog stdout records, never debug observer copies.

Keep simulator stderr in a separate file: merging buffered stdout with the
testbench's stderr can splice records. Malformed canonical records fail closed.
"""

import argparse
from collections import Counter
import re
import sys


FAULT = re.compile(
    r"\[FAULT\] vec=(\d+) err=([0-9a-fA-F]{8}) pc=[0-9a-fA-F]{8} "
    r"state=\d+ v86=[01] depth=\d+"
)


def read_counts(lines):
    counts = Counter()
    for lineno, line in enumerate(lines, 1):
        if "[FAULT]" not in line:
            # VEN_DBG_CORE's `tb: FLT` is an additional observer of the same
            # start_fault call, not a second fault. Other stdout is diagnostic.
            continue
        match = FAULT.fullmatch(line.rstrip("\r\n"))
        if match is None:
            raise ValueError(f"line {lineno}: malformed/noncanonical [FAULT] record; "
                             "capture simulator stderr separately")
        counts[int(match[1]), int(match[2], 16)] += 1
    return counts


def check_counts(counts, expected, allowed=()):
    for pair, want in expected.items():
        got = counts[pair]
        if got != want:
            raise ValueError(f"vec={pair[0]} err={pair[1]:08x}: got {got}, want {want}")
    unexpected = counts.keys() - expected.keys() - set(allowed)
    if unexpected:
        raise ValueError(f"unexpected vector/error classes: "
                         f"{[(v, f'{e:08x}', counts[v, e]) for v, e in sorted(unexpected)]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log")
    parser.add_argument("--expect", action="append", default=[], metavar="VEC:ERR:COUNT")
    parser.add_argument("--allow", action="append", default=[], metavar="VEC:ERR")
    args = parser.parse_args()
    try:
        expected = {}
        for spec in args.expect:
            vec, err, count = (int(part, 0) for part in spec.split(":"))
            if (vec, err) in expected or count < 0:
                raise ValueError(f"invalid/repeated expectation: {spec}")
            expected[vec, err] = count
        allowed = set()
        for spec in args.allow:
            vec, err = (int(part, 0) for part in spec.split(":"))
            allowed.add((vec, err))
        with open(args.log, encoding="utf-8") as stream:
            counts = read_counts(stream)
        check_counts(counts, expected, allowed)
    except (OSError, ValueError) as exc:
        print(f"FATAL: {args.log}: {exc}", file=sys.stderr)
        return 1
    summary = ", ".join(f"vec={v} err={e:08x}: {n}" for (v, e), n in sorted(counts.items()))
    print(f"  CANONICAL-FAULTLOG-OK: {sum(counts.values())} records ({summary})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
