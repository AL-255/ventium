#!/usr/bin/env python3
"""Keep only slow retire candidates with matching owner PC and x86 byte length.

The output unifies fast and accepted slow records by legacy callback ordinal.
Rejected candidates stay counted by reason; absent ordinals remain gaps. This
does not normalize REP elements or prove asynchronous FP completion.
"""

from __future__ import annotations

import argparse
from collections import Counter
import csv
import json
from pathlib import Path

import capstone

from validate_fast_bytes import owners, validate


FIELDNAMES = ("cycle", "legacy_ordinal", "pc", "physical_start", "slot",
              "owner", "mode16", "bytes")


def slow_reason(row: dict, known: dict[int, int], decoders: dict) -> str:
    ordinal = int(row["legacy_ordinal"])
    pc = int(row["pc"], 16)
    if ordinal not in known:
        return "unreported_owner"
    if known[ordinal] != pc:
        return "owner_pc_mismatch"
    mode16 = int(row["mode16"])
    if mode16 not in (0, 1):
        return "invalid_code_mode"
    raw = bytes.fromhex(row["bytes"])
    decoded = list(decoders[mode16].disasm(raw, pc, count=1))
    if len(decoded) != 1 or decoded[0].size != len(raw):
        return "instruction_length_mismatch"
    return "accepted"


def merge(prefix: Path) -> dict:
    validate(prefix)
    known = owners(Path(str(prefix) + ".commit_observations.bin"))
    decoders = {0: capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32),
                1: capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)}
    rows = []
    counts = Counter()
    with Path(str(prefix) + ".fast_issue_bytes.tsv").open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            rows.append(row)
            counts["fast_accepted"] += 1
    with Path(str(prefix) + ".slow_candidate_bytes.tsv").open(newline="", encoding="utf-8") as stream:
        for candidate in csv.DictReader(stream, delimiter="\t"):
            reason = slow_reason(candidate, known, decoders)
            counts["slow_" + reason] += 1
            if reason == "accepted":
                rows.append({"cycle": candidate["cycle"],
                             "legacy_ordinal": candidate["legacy_ordinal"],
                             "pc": candidate["pc"], "physical_start": "",
                             "slot": "U", "owner": "slow",
                             "mode16": candidate["mode16"], "bytes": candidate["bytes"]})
    rows.sort(key=lambda row: int(row["legacy_ordinal"]))
    previous = -1
    for row in rows:
        ordinal = int(row["legacy_ordinal"])
        if ordinal <= previous:
            raise ValueError("duplicate or nonmonotonic verified owner ordinal")
        previous = ordinal
    output = Path(str(prefix) + ".verified_issue_bytes.tsv")
    with output.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDNAMES, delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)
    return {"output": str(output), "verified_instructions_legacy": len(rows),
            "counts": dict(sorted(counts.items())), "rep_normalized": False,
            "fp_completion_canonical": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix", type=Path)
    args = parser.parse_args()
    print(json.dumps(merge(args.prefix), sort_keys=True))


if __name__ == "__main__":
    main()
