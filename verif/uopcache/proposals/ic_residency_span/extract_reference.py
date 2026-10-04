#!/usr/bin/env python3
"""Mechanically extract current raw functions, front span, and old callers.

The test oracle never contains a hand-maintained optimized implementation.
Fail closed if source signatures or caller spelling drift. Output is a scratch
test include, not a production source modification.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re


SIGNATURES = (
    "function automatic logic ic_present",
    "function automatic logic [IC_WAYW-1:0] ic_hit_way",
    "function automatic logic [7:0] ic_byte",
    "function automatic logic ic_buffered",
)


def extract_function(source: str, signature: str) -> str:
    if source.count(signature + "(") != 1:
        raise ValueError(f"expected exactly one function: {signature}")
    first = source.index(signature + "(")
    last = source.index("endfunction", first) + len("endfunction")
    return source[first:last]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--core", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source = args.core.read_text(encoding="utf-8")
    begin, end = "// BEGIN IC FRONT SPAN", "// END IC FRONT SPAN"
    if source.count(begin) != 1 or source.count(end) != 1:
        raise ValueError("expected exactly one production front-span marker pair")
    span = source[source.index(begin):source.index(end) + len(end)]
    if "ic_front_probe(flin)" not in span or "ic_front_probe(flin_nl)" not in span:
        raise ValueError("production span lacks the required A/B queries")
    callers = []
    for name in ("pipe_bytes_ok", "pf_miss_fa", "v_bytes_ok"):
        matches = re.findall(r"(?m)^\s*" + name + r"\s*=.*?;", source, re.S)
        if len(matches) != 1:
            raise ValueError(f"expected exactly one old caller assignment: {name}")
        assignment = matches[0].strip()
        if "ic_present(" not in assignment:
            raise ValueError(f"old caller is already factored: {name}")
        callers.append(re.sub(r"^" + name + r"\b", "old_" + name, assignment))
    if not re.search(r"wire\s+\[5:0\]\s+fp_pipe_decode_win_last\s*=.*?6'd6\s*:\s*6'd5;", source):
        raise ValueError("decode-window last-byte range contract changed")
    if "localparam int IWORDS = 4;" not in source:
        raise ValueError("slow-window size contract changed")
    digest = hashlib.sha256(source.encode()).hexdigest()
    output = (f"// EXTRACTED FROM {args.core}\n// sha256={digest}\n\n" +
              "\n\n".join(extract_function(source, s) for s in SIGNATURES) +
              "\n\n" + span + "\n\nalways_comb begin\n" +
              "\n".join("  " + text for text in callers) + "\nend\n")
    args.output.write_text(output, encoding="utf-8")
    print(f"IC-RESIDENCY-REFERENCE-EXTRACT-OK core_sha256={digest}")


if __name__ == "__main__":
    main()
