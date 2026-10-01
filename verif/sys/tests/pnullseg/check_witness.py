#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Grade CLOSED RTL evidence only; never launch/rebuild a DUT or QEMU.

Require the reviewed frozen binary/compile-record hash pair and check the
actual colocated Verilator command, not an environment claim. This supplements
the caller's frozen-build/source-closure receipt; it cannot create that receipt.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
sys.path.insert(0, str(REPO / "verif/diff"))
import tracefmt


# Match the fixture's stage macro, not the terminal success registers. The
# legacy DPI stream includes a fault-delivery event at the original fault PC;
# that event is not a committed null memory instruction (core_int_deliver.svh).
STAGE_GPRS = {"eax": 0x12345678, "ecx": 0x23456789, "edx": 0x3456789A,
              "ebx": 0x456789AB, "ebp": 0x56789ABC, "esi": 0x6789ABCD,
              "edi": 0x789ABCDE}
DEFINED_FLAGS_MASK = 0x003E7FD5  # Same as assembly; fault-image RF excluded.
STAGE_FLAGS = 0x00000CD5


def digest(path):
    with Path(path).open("rb") as src:
        return hashlib.file_digest(src, "sha256").hexdigest()


def compile_profile(text):
    commands = [line[3:-1] for line in text.splitlines()
                if line.startswith('C "') and line.endswith('"')]
    if len(commands) != 1:
        raise ValueError("expected one complete Verilator C command record")
    argv = shlex.split(commands[0])
    defines = set()
    for arg in argv:
        if arg.startswith("+define+"):
            defines.update(item.split("=", 1)[0]
                           for item in arg[len("+define+"):].split("+"))
    if "VEN_SEG_ENFORCE" not in defines:
        raise ValueError("actual compile record lacks VEN_SEG_ENFORCE")
    return argv


def symbols(elf):
    result = subprocess.run(["nm", "-n", str(elf)], check=True,
                            text=True, capture_output=True, timeout=5)
    return {parts[2]: int(parts[0], 16) for line in result.stdout.splitlines()
            if len(parts := line.split()) == 3}


def check_faults(log, expected):
    entries = []
    for line in log.splitlines():
        if "[FAULT]" not in line:
            continue
        match = re.search(r"\[FAULT\]\s+vec=(\d+)\s+err=([0-9a-fA-F]{8})"
                          r"\s+pc=([0-9a-fA-F]{8})(?:\s|$)", line)
        if not match:
            raise ValueError("malformed fault-log entry")
        entries.append((int(match[1]), int(match[2], 16), int(match[3], 16)))
    if entries != [(13, 0, pc) for pc in expected]:
        raise ValueError(f"wrong/missing/additional faults: {entries!r}")


def check_delivery_records(rows, faults, sym):
    """Qualify four legacy delivery markers and their adjacent PUSHAL records."""
    pcs = [tracefmt.parse_hex(row["pc"]) for row in rows]
    markers = [(n, pc) for n, pc in enumerate(pcs) if pc in faults]
    if [pc for _, pc in markers] != faults:
        raise ValueError("missing/duplicate/out-of-order fault-delivery marker")
    handlers = [n for n, pc in enumerate(pcs) if pc == sym["gp_handler"]]
    if handlers != [n + 1 for n, _ in markers]:
        raise ValueError("each delivery marker must immediately precede one GP handler entry")
    for case, (n, _) in enumerate(markers):
        selectors = {"cs": 8, "ss": 0x10, "fs": 0x10, "gs": 0x10,
                     "ds": 0 if case < 2 else 0x10,
                     "es": 0x10 if case < 2 else 3}
        # The completed same-CPL #GP frame consumes 16 bytes. The adjacent
        # gp_handler record is POST-PUSHAL and consumes another 32 bytes.
        for row, esp in ((rows[n], 0x8FFF0), (rows[n + 1], 0x8FFD0)):
            for key, value in {**STAGE_GPRS, **selectors, "esp": esp}.items():
                if tracefmt.parse_hex(row[key]) != value:
                    raise ValueError(f"wrong delivery/handler {key} at record {row['n']}")
            if tracefmt.parse_hex(row["eflags"]) & DEFINED_FLAGS_MASK != STAGE_FLAGS:
                raise ValueError(f"wrong delivery/handler defined EFLAGS at record {row['n']}")
    return pcs


def grade_records(trace, log, sym, manifest, return_code):
    if return_code != manifest["exit_code"]:
        raise ValueError("DUT did not reap with PASS isa-debug-exit status85")
    if (trace.hdr.get("vtrace") != 1 or trace.hdr.get("producer") != "rtl"
            or trace.mode != "func" or not trace.sys):
        raise ValueError("expected RTL functional system trace")
    rows = trace.records
    if not rows or len(rows) >= manifest["max_insn"]:
        raise ValueError("empty or instruction-cap-exhausted trace")
    required = tracefmt.func_compare_keys(False, True)
    for n, row in enumerate(rows):
        if row.get("n") != n or not all(key in row for key in required):
            raise ValueError("incomplete/non-contiguous architectural trace")
        for key in required:
            value = tracefmt.parse_hex(row[key])
            if not 0 <= value < (1 << tracefmt._WIDTH[key]):
                raise ValueError(f"out-of-range architectural field {key}")
    stops = [line for line in log.splitlines() if line.startswith("tb: stop:")]
    if len(stops) != 1 or "isa-debug-exit (out 0xf4)" not in stops[0]:
        raise ValueError("not a single genuine debug-exit closure")
    footers = re.findall(r"^tb: retired (\d+) instructions in (\d+) clocks",
                         log, re.MULTILINE)
    if len(footers) != 1 or int(footers[0][0]) != len(rows):
        raise ValueError("missing/mismatching retirement footer")
    if re.search(r"%Error|Assertion failed|FATAL|CPU HUNG|UNIMPLEMENTED", log):
        raise ValueError("fatal observer/DUT error in log")
    faults = [sym[item["symbol"]] for item in manifest["faults"]]
    check_faults(log, faults)
    pcs = check_delivery_records(rows, faults, sym)
    # io_exit may precede OUT retirement; the immediately preceding MOV DX
    # and OUT itself both carry the complete terminal witness set.
    if pcs[-1] not in {sym["do_exit"], sym["do_out"]}:
        raise ValueError("final record is not the real debug-exit path")
    for key, value in manifest["witnesses"].items():
        if tracefmt.parse_hex(rows[-1][key]) != int(value, 16):
            raise ValueError(f"wrong terminal {key}: {rows[-1][key]}")
    return {"result": "PASS", "trace_records": len(rows),
            "legacy_reported_retires": len(rows), "fault_delivery_events": 4,
            "record_count_note": "Legacy DPI count includes fault-delivery events, not instruction commits only.",
            "faults": 4, "legal_controls": 6, "oracle": manifest["oracle"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--return-code", type=int, required=True)
    parser.add_argument("--elf", type=Path, default=HERE / "pnullseg.elf")
    parser.add_argument("--tb-bin", type=Path, required=True)
    parser.add_argument("--tb-sha256", required=True)
    parser.add_argument("--compile-record", type=Path, required=True)
    parser.add_argument("--compile-sha256", required=True)
    parser.add_argument("--compile-cwd", type=Path, default=REPO / "verif/tb",
                        help="reviewed original Verilator cwd for relative -Mdir")
    args = parser.parse_args()
    if digest(args.tb_bin) != args.tb_sha256:
        raise ValueError("frozen TB binary hash mismatch")
    if digest(args.compile_record) != args.compile_sha256:
        raise ValueError("frozen compile record hash mismatch")
    if args.compile_record.resolve().parent != args.tb_bin.resolve().parent:
        raise ValueError("compile metadata is not from this TB output directory")
    argv = compile_profile(args.compile_record.read_text())
    if "-Mdir" not in argv:
        raise ValueError("actual Verilator command has no -Mdir")
    mdir = Path(argv[argv.index("-Mdir") + 1])
    if not mdir.is_absolute():
        mdir = args.compile_cwd / mdir
    if mdir.resolve() != args.tb_bin.resolve().parent:
        raise ValueError("actual Verilator -Mdir does not match frozen TB")
    manifest = json.loads((HERE / "manifest.json").read_text())
    receipt = grade_records(tracefmt.read_trace(str(args.trace)), args.log.read_text(),
                            symbols(args.elf), manifest, args.return_code)
    receipt.update(tb_sha256=args.tb_sha256, compile_sha256=args.compile_sha256,
                   trace_sha256=digest(args.trace), log_sha256=digest(args.log),
                   elf_sha256=digest(args.elf))
    print(json.dumps(receipt, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f"PNULLSEG-WITNESS-FAIL: {error}")
