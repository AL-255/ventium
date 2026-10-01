#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Grade CLOSED legal pselnull RTL evidence. Never launch a DUT or QEMU.

Both system and segment runners use this contract. Historical unenforced
LEGACY_NULL_USE images are not standard evidence. QEMU's different case-D
ordering remains honestly pinned separately; this grades the existing RTL
outgoing-context/no-busy-write witnesses, not a masked differential.
"""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path
import json
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
sys.path.insert(0, str(REPO / "verif/diff"))
import tracefmt

WITNESSES = dict(edi=0x0BABE001, esi=0x00010004, ebp=0x010A0004,
                 ebx=0x0000898B, ecx=0x0BABE001, eax=0x42,
                 esp=0xB800, cs=8, ss=0x10, ds=0x10, es=0x10,
                 fs=0x10, gs=0x10, cr3=0x11000)


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def symbols(elf):
    result = subprocess.run(["nm", "-n", str(elf)], check=True, text=True,
                            capture_output=True, timeout=5)
    return {parts[2]: int(parts[0], 16) for line in result.stdout.splitlines()
            if len(parts := line.split()) == 3}


def grade_records(trace, log, sym, return_code):
    if return_code != 133:
        raise ValueError("actual reaped status must be133 (AL42 debug exit)")
    if (trace.hdr.get("vtrace") != 1 or trace.hdr.get("producer") != "rtl"
            or trace.mode != "func" or not trace.sys):
        raise ValueError("expected functional RTL system trace")
    rows = trace.records
    if not rows or len(rows) >= 1200:
        raise ValueError("empty or instruction-capped trace")
    required = tracefmt.func_compare_keys(False, True)
    for n, row in enumerate(rows):
        if row.get("n") != n or not all(key in row for key in required):
            raise ValueError("incomplete/noncontiguous architectural trace")
        for key in required:
            value = tracefmt.parse_hex(row[key])
            if not 0 <= value < (1 << tracefmt._WIDTH[key]):
                raise ValueError(f"out-of-range architectural field {key}")
    stops = [line for line in log.splitlines() if line.startswith("tb: stop:")]
    if len(stops) != 1:
        raise ValueError("expected one complete debug-exit stop")
    match = re.fullmatch(r"tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) "
                         r"after (\d+) retired in (\d+) clocks", stops[0])
    if not match or int(match[1]) != len(rows):
        raise ValueError("missing/mismatching genuine debug-exit closure")
    footers = re.findall(r"^tb: retired (\d+) instructions in (\d+) clocks "
                         r"\(bus: \d+ reads, \d+ writes\)$", log, re.MULTILINE)
    if (len(footers) != 1 or int(footers[0][0]) != len(rows)
            or int(footers[0][1]) != int(match[2]) or int(match[2]) <= 0):
        raise ValueError("missing/mismatching complete retirement footer")
    if re.search(r"%Error|Assertion failed|FATAL|CPU HUNG|UNIMPLEMENTED", log):
        raise ValueError("fatal model/observer error in closed log")
    faults = []
    for line in log.splitlines():
        if "[FAULT]" not in line:
            continue
        fault = re.search(r"\[FAULT\]\s+vec=(\d+)\s+err=([0-9a-fA-F]{8}) "
                          r"pc=([0-9a-fA-F]{8})(?:\s|$)", line)
        if not fault:
            raise ValueError("malformed fault-log line")
        faults.append((int(fault[1]), int(fault[2], 16), int(fault[3], 16)))
    if faults != [(13, 4, sym["fault_c"]), (10, 4, sym["fault_d"])]:
        raise ValueError(f"expected exact ordered GP4/TS4, no PF/extra faults: {faults!r}")
    if not any(tracefmt.parse_hex(row["cs"]) == 4 for row in rows):
        raise ValueError("valid LDT-entry0 case-B execution missing")
    for name in ("null_load_a", "task_e"):
        matches = [row for row in rows if tracefmt.parse_hex(row["pc"]) == sym[name]]
        if len(matches) != 1 or tracefmt.parse_hex(matches[0]["ds"]) != 0:
            raise ValueError(f"missing/wrong visible null-DS proof at {name}")
    last = rows[-1]
    if tracefmt.parse_hex(last["pc"]) not in {sym["exit_port"], sym["exit_out"]}:
        raise ValueError("final record is not the actual debug-exit path")
    for key, value in WITNESSES.items():
        if tracefmt.parse_hex(last[key]) != value:
            raise ValueError(f"wrong terminal {key}: {last[key]}")
    if tracefmt.parse_hex(last["edx"]) & 0xFFFF != 0xF4:
        raise ValueError("terminal DX is not debug-exit portF4")
    if tracefmt.parse_hex(last["cr0"]) & 0x80000001 != 0x80000001:
        raise ValueError("case-E paging/protected-mode state missing")
    return {"result": "PASS", "cases": ["B", "C", "D", "A", "E"],
            "trace_records": len(rows), "legacy_reported_retires": len(rows),
            "faults": [[13, 4], [10, 4]], "page_faults": 0,
            "return_code": 133,
            "qualification": "Legal SS sentinels/visible null selectors; not a hidden-base-zero proof. Case-D QEMU ordering gap remains separate."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--return-code", type=int, required=True)
    parser.add_argument("--elf", type=Path, default=HERE / "pselnull.elf")
    args = parser.parse_args()
    receipt = grade_records(tracefmt.read_trace(str(args.trace)), args.log.read_text(),
                            symbols(args.elf), args.return_code)
    receipt.update(trace_sha256=digest(args.trace), log_sha256=digest(args.log),
                   elf_sha256=digest(args.elf))
    print(json.dumps(receipt, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f"PSELNULL-WITNESS-FAIL: {error}")
