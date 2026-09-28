#!/usr/bin/env python3
"""Cross-check the fail-closed fast-byte export against retire owners and x86 decode."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
import struct

try:
    import capstone
except ImportError as exc:
    raise SystemExit("install python-capstone to validate independently decoded bytes") from exc


# tools/state_delta_analyze.cpp writes these fields individually, no padding.
COMMIT = struct.Struct("=QQIII48s")


def owners(path: Path) -> dict[int, int]:
    result: dict[int, int] = {}
    with path.open("rb") as stream:
        while record := stream.read(COMMIT.size):
            if len(record) != COMMIT.size:
                raise ValueError("truncated commit observation")
            end, _cycle, u_pc, v_pc, count, _snapshot = COMMIT.unpack(record)
            if count not in (1, 2):
                raise ValueError("invalid commit width")
            result[end] = v_pc if count == 2 else u_pc
            if count == 2:
                result[end - 1] = u_pc
    return result


def summary(path: Path) -> dict[str, int]:
    with path.open(newline="", encoding="utf-8") as stream:
        return {name: int(value) for name, value in list(csv.reader(stream, delimiter="\t"))[1:]
                if name in {"fast_issue_bytes_instructions", "final_registered_retire", "edge_retired"}}


def validate(prefix: Path) -> tuple[int, int]:
    known = owners(Path(str(prefix) + ".commit_observations.bin"))
    counts = summary(Path(str(prefix) + ".summary.tsv"))
    decoders = {mode: capstone.Cs(capstone.CS_ARCH_X86, mode)
                for mode in (capstone.CS_MODE_16, capstone.CS_MODE_32)}
    lines = 0
    final_pending = []
    with Path(str(prefix) + ".fast_issue_bytes.tsv").open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            ordinal, pc = int(row["legacy_ordinal"]), int(row["pc"], 16)
            blob = bytes.fromhex(row["bytes"])
            mode16 = int(row["mode16"])
            if mode16 not in (0, 1):
                raise ValueError(f"invalid code mode at ordinal {ordinal}")
            decoder = decoders[capstone.CS_MODE_16 if mode16 else capstone.CS_MODE_32]
            decoded = list(decoder.disasm(blob, pc, count=1))
            if len(decoded) != 1 or decoded[0].size != len(blob):
                raise ValueError(f"x86 length mismatch at ordinal {ordinal}")
            if ordinal in known:
                if known[ordinal] != pc:
                    raise ValueError(f"owner PC mismatch at ordinal {ordinal}")
            else:
                final_pending.append(ordinal)
            lines += 1
    # The final registered retire pulse is outside the host callback window.
    # It is the sole permitted owner-lookup gap, never an arbitrary exemption.
    if final_pending and (len(final_pending) > counts["final_registered_retire"] or
                          final_pending != list(range(max(known) + 1, max(known) + 1 + len(final_pending)))):
        raise ValueError(f"unexpected unreported owners {final_pending}")
    if lines != counts["fast_issue_bytes_instructions"]:
        raise ValueError("exported byte count disagrees with analyzer summary")
    if lines > counts["edge_retired"] + counts["final_registered_retire"]:
        raise ValueError("more byte records than retirement events")
    return lines, len(final_pending)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix", type=Path, help="state_delta_analyze output prefix")
    args = parser.parse_args()
    lines, pending = validate(args.prefix)
    print(f"FAST-ISSUE-BYTES-OK instructions={lines} final_pending={pending}")


if __name__ == "__main__":
    main()
