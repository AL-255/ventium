#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Read canonical producer traces; do not emit or hand-format .vtrace files."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "verif" / "diff"))
from tracefmt import parse_hex, read_trace  # noqa: E402

DATA = (0xFF, 0x1E, 0x42, 0xA5, 0x5A, 0x00, 0x7F, 0x80, 0xFE)
MAX_INSN = 5000


def read_symbols(path: Path) -> dict[str, int]:
    result: dict[str, int] = {}
    for line in path.read_text().splitlines():
        fields = line.split()
        if len(fields) == 3:
            result[fields[2]] = int(fields[0], 16)
    return result


def check(path: Path, symbols: Path, case: int) -> None:
    trace = read_trace(str(path))
    rows = trace.records
    if not trace.hdr.get("sys"):
        raise ValueError("system-mode trace required")
    if not rows or len(rows) >= MAX_INSN:
        raise ValueError(f"incomplete/limited trace: {len(rows)} records")
    last = rows[-1]
    for field, expected in {"eax": 0x42, "ebp": 0x56524D00 + case}.items():
        if parse_hex(last[field]) != expected:
            raise ValueError(f"self-check exit failed: {field}={last[field]}")

    # A faulting MOV can be absent from retire records, or carry post-handler
    # CS in a producer's exception-step record. Select only successful V86
    # commits and pin all nine byte results/parent registers, not a fault-record
    # count convention. The assembly separately checks CR2/error/source frame.
    sym = read_symbols(symbols)
    if sym["v86_entry"] != 0x10000:
        raise ValueError("fixture linker must place v86_entry at VMA 0x10000")
    # Canonical system producers store the fetched EIP offset, not CS.base+EIP.
    # nm reports the section VMA, so anchor it to the V86 run segment explicitly.
    address = sym["read_byte"] - sym["v86_entry"]
    loads = [row for row in rows if parse_hex(row["pc"]) == address
             and parse_hex(row["cs"]) == 0x1000]
    if len(loads) != len(DATA):
        raise ValueError(f"expected 9 successful V86 byte reads, got {len(loads)}")
    for ordinal, (row, byte) in enumerate(zip(loads, DATA)):
        expected = {
            "eax": 0xABCD0000 | ((0x7E + ordinal) << 8) | byte,
            "ebx": 0x13570FFD + ordinal,
            "ecx": 0x24680009 - ordinal,
            "edi": 0x87650000 + ordinal,
            "esi": 0x11223344, "ebp": 0x55AA55AA,
            "edx": 0xDEAD0066, "esp": 0xF000,
            "es": 0x2000, "ds": 0x3000, "ss": 0x4000,
            "fs": 0x3100, "gs": 0x3200,
        }
        for field, value in expected.items():
            actual = parse_hex(row[field])
            if actual != value:
                raise ValueError(f"read {ordinal} {field}: {actual:#x} != {value:#x}")
        if parse_hex(row["eflags"]) & 0x23000 != 0x23000:
            raise ValueError(f"read {ordinal} lost VM/IOPL3")
        # Hidden fields are optional in the canonical contract. If a producer
        # has them, they must describe the restored V86 base/default context.
        for field, value in {"es_base": 0x20000, "cs_base": 0x10000}.items():
            if field in row and parse_hex(row[field]) != value:
                raise ValueError(f"read {ordinal} wrong {field}: {row[field]}")
    print(f"PV86-MOVRESTART-TRACE-OK case={case} records={len(rows)} byte_reads=9")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", required=True, type=int, choices=range(1, 5))
    parser.add_argument("--symbols", required=True, type=Path)
    parser.add_argument("trace", type=Path)
    args = parser.parse_args()
    try:
        check(args.trace, args.symbols, args.case)
    except (KeyError, OSError, ValueError) as error:
        print(f"PV86-MOVRESTART-TRACE-FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
