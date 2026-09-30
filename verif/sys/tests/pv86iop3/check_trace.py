#!/usr/bin/env python3
"""Check canonical producer traces and actual TB I/O counter diagnostics."""
import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "verif/diff"))
from tracefmt import parse_hex, read_trace


def symbols(path):
    result = {}
    for line in path.read_text().splitlines():
        f = line.split()
        if len(f) == 3:
            result[f[2]] = int(f[0], 16)
    return result


def check(args):
    trace = read_trace(str(args.trace))
    rows = trace.records
    if trace.hdr.get("sys") is not True or trace.hdr.get("mode") != "func":
        raise ValueError("full architectural system trace required")
    if not rows or len(rows) >= 5000:
        raise ValueError("empty or retirement-capped trace")
    for i, row in enumerate(rows):
        if type(row["n"]) is not int or row["n"] != i:
            raise ValueError("noncontiguous retirement index")
    sym = symbols(args.symbols)
    if sym["v86_entry"] != 0x10000:
        raise ValueError("unexpected V86 linker base")
    denied = args.case not in (13, 14)
    last = rows[-1]
    expected = {"eax": 0x42, "ebx": args.case, "ecx": int(denied),
                "edi": 0, "esi": 0xC0DEC0DE}
    if args.expect_red:
        if not 1 <= args.case <= 12:
            raise ValueError("known RED applies only to V86/IOPL3 denied cases")
        if parse_hex(last["eax"]) != 0x43 or parse_hex(last["ecx"]) != 0:
            raise ValueError("not the missing target-#GP self-check failure")
        if parse_hex(last["edi"]) == 0:
            raise ValueError("missing negative self-check error")
        io_pc = sym["io_fault"] - sym["v86_entry"]
        hits = [r for r in rows if parse_hex(r["pc"]) == io_pc
                and parse_hex(r["cs"]) == 0x1000
                and parse_hex(r["eflags"]) & 0x23000 == 0x23000]
        if len(hits) != 1:
            raise ValueError("no unique illegal V86/IOPL3 I/O retirement")
    else:
        for key, value in expected.items():
            if parse_hex(last[key]) != value:
                raise ValueError(f"self-check failed {key}: {last[key]}")
    entries = [r for r in rows if parse_hex(r["pc"]) == sym["gp_handler"]]
    expected_entries = 1 if args.expect_red or not denied else 2
    if len(entries) != expected_entries:
        raise ValueError(f"unexpected #GP handler entries {len(entries)}")
    if args.rtl_log:
        log = args.rtl_log.read_text()
        matches = re.findall(r"co-sim: (\d+) IN reads serviced[^\n]*?, "
                             r"(\d+) OUT writes consumed, (\d+) port/size "
                             r"desync\(s\), isa-debug-exit reached", log)
        if len(matches) != 1:
            raise ValueError("missing unique completed I/O diagnostics")
        actual = tuple(map(int, matches[0]))
        expected_io = (0, 2 if args.case in (13, 14) else 1, 0)
        if args.expect_red:
            is_input = args.case % 2 == 0
            expected_io = (1, 1, 0) if is_input else (0, 2, 0)
        if actual != expected_io:
            raise ValueError(f"I/O side effects {actual} != {expected_io}")
    print(f"PV86-IOP3-{'EXPECTED-RED' if args.expect_red else 'TRACE-OK'} "
          f"case={args.case} records={len(rows)} gp_entries={len(entries)}")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--case", type=int, choices=range(1, 16), required=True)
    p.add_argument("--symbols", type=Path, required=True)
    p.add_argument("--rtl-log", type=Path)
    p.add_argument("--expect-red", action="store_true")
    p.add_argument("trace", type=Path)
    args = p.parse_args()
    try:
        check(args)
    except (ValueError, KeyError, OSError) as exc:
        print(f"PV86-IOP3-CHECK-FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
