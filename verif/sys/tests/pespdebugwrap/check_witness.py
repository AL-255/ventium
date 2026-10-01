#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Pure closed-artifact checker; importing never launches/evaluates a DUT."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
SHARED = REPO / "verif/sys/run-pverrw-gate.py"
spec = importlib.util.spec_from_file_location("pespdebugwrap_closed_contracts", SHARED)
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)
tracefmt = contracts.tracefmt
MAX_INSN = 1000


def variant(case):
    if type(case) is not int or case not in (1, 2):
        raise ValueError("case must be integer1 or2")
    return dict(case_id=case, initial_esp=0xBEEF7000, destination_esp=0xDEAD0000,
                handler_esp=0xDEADFFF4, expected_dr6=0xFFFF4FF0,
                expected_saved_flags=0x102, expected_handler_count=1)


def validate_image(case, sym, image):
    info = variant(case)
    for name, value in info.items():
        if sym.get(name) != value:
            raise ValueError(f"wrong ELF fixture constant {name}")
    for name in ("set_tf_popfl", "tested_op", "tested_end", "db_handler", "capture_ip",
                 "capture_cs", "capture_flags", "capture_dr6", "clear_saved_tf",
                 "tested_iret", "do_exit", "set_exit_port", "do_out", "fail"):
        if not 0xF0000 <= sym.get(name, -1) < 0xFFFF0:
            raise ValueError(f"missing/out-of-ROM ELF label {name}")
    if len(image) != 65536:
        raise ValueError("BIOS must be exactly64KiB")
    if sym.get("expected_frame_ip") != sym["tested_end"] - 0xF0000:
        raise ValueError("saved IP is not the actual post-test segment-relative offset")
    opcode = b"\xbc\x00\x00\xad\xde" if case == 1 else b"\x8d\x20"
    at = sym["tested_op"] - 0xF0000
    if image[at:at + len(opcode)] != opcode or sym["tested_end"] != sym["tested_op"] + len(opcode):
        raise ValueError("not the exact reviewed full-width MOV/LEA ESP")
    at = sym["set_tf_popfl"] - 0xF0000
    if image[at] != 0x9D or sym["tested_op"] != sym["set_tf_popfl"] + 1:
        raise ValueError("POPF must immediately precede the tested instruction")
    if image[sym["tested_iret"] - 0xF0000] != 0xCF:
        raise ValueError("return must be DWORD IRET")
    at = sym["set_exit_port"] - 0xF0000
    if (sym["do_out"] != sym["set_exit_port"] + 4
            or image[at:at + 5] != b"\x66\xba\xf4\x00\xee"):
        raise ValueError("ELF/BIOS debug-exit path mismatch")
    return info


def grade_trace(trace, case, sym, image, producer):
    info = validate_image(case, sym, image)
    rows = contracts.validate_trace(trace, producer)
    if len(rows) >= MAX_INSN:
        raise ValueError("fixture reached instruction cap")
    positions = {}
    names = ("set_tf_popfl", "tested_op", "db_handler", "capture_ip", "capture_cs",
             "capture_flags", "capture_dr6", "clear_saved_tf", "tested_iret", "tested_end")
    for name in names:
        hits = [i for i, row in enumerate(rows)
                if tracefmt.parse_hex(row["pc"]) == sym[name] - 0xF0000]
        if len(hits) != 1:
            raise ValueError(f"{name} must execute exactly once")
        positions[name] = hits[0]
    if (positions["tested_op"] != positions["set_tf_popfl"] + 1
            or any(positions[a] >= positions[b] for a, b in zip(names, names[1:]))):
        raise ValueError("TF setup/one trap/handler/return execution order mismatch")
    if any(tracefmt.parse_hex(row["pc"]) == sym["fail"] - 0xF0000 for row in rows):
        raise ValueError("in-guest frame/debug self-check failed")
    setup = rows[positions["set_tf_popfl"]]
    if (tracefmt.parse_hex(setup["esp"]) != info["initial_esp"]
            or tracefmt.parse_hex(setup["eflags"]) & 0x100 != 0x100):
        raise ValueError("POPF trapped prematurely or failed to install TF")
    for name in ("tested_op", "db_handler"):
        row = rows[positions[name]]
        if (tracefmt.parse_hex(row["esp"]) != info["handler_esp"]
                or tracefmt.parse_hex(row["cs"]) != 8
                or tracefmt.parse_hex(row["ss"]) != 0x20
                or tracefmt.parse_hex(row["eflags"]) & 0x34100):
            raise ValueError("wrong actual #DB frame/control/cleared live-TF state")
    for name in ("tested_iret", "tested_end"):
        row = rows[positions[name]]
        if (tracefmt.parse_hex(row["esp"]) != info["destination_esp"]
                or tracefmt.parse_hex(row["eflags"]) & 0x100):
            raise ValueError("wrong restored full ESP or saved TF not cleared")
    for name, key, value in (("capture_ip", "edi", sym["expected_frame_ip"]),
                             ("capture_cs", "edx", 8),
                             ("capture_flags", "ebp", info["expected_saved_flags"]),
                             ("capture_dr6", "esi", info["expected_dr6"])):
        if tracefmt.parse_hex(rows[positions[name]][key]) != value:
            raise ValueError(f"wrong actual saved frame/debug readback {name}")
    final = rows[-1]
    if tracefmt.parse_hex(final["pc"]) not in {
            sym["set_exit_port"] - 0xF0000, sym["do_out"] - 0xF0000}:
        raise ValueError("final record is not successful actual exit path")
    witnesses = dict(eax=0x42, ebx=case, ecx=info["handler_esp"], esp=info["destination_esp"],
                     ebp=1, esi=info["expected_dr6"], edi=sym["expected_frame_ip"], edx=0xF4,
                     cs=8, ss=0x20, ds=0x10, es=0x10, fs=0x10, gs=0x10, cr2=0, cr3=0)
    for name, value in witnesses.items():
        if tracefmt.parse_hex(final[name]) != value:
            raise ValueError(f"wrong final witness {name}")
    if tracefmt.parse_hex(final["cr0"]) & 0x80000001 != 1:
        raise ValueError("fixture must remain protected and unpaged")
    return len(rows)


def grade_native(trace, stdout, stderr, case, sym, image, return_code):
    if return_code != 133:
        raise ValueError("native actual wait status must be133")
    count = grade_trace(trace, case, sym, image, "rtl")
    for name, text in (("stdout", stdout), ("stderr", stderr)):
        if (text and not text.endswith("\n")) or contracts.FATAL.search(text):
            raise ValueError(f"truncated/fatal native {name}")
    log = stdout + stderr  # Only independently closed regular files, not pipe streams.
    faults = contracts.check_faultlog.read_counts(log.splitlines(keepends=True))
    if faults:
        raise ValueError(f"unexpected ordinary fault: {dict(faults)}")
    stops = [line for line in log.splitlines() if line.startswith("tb: stop:")]
    match = re.fullmatch(r"tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) "
                         r"after (\d+) retired in (\d+) clocks", stops[0]) if len(stops) == 1 else None
    footer = re.findall(r"^tb: retired (\d+) instructions in (\d+) clocks "
                        r"\(bus: \d+ reads, \d+ writes\)$", log, re.MULTILINE)
    if not match or int(match[1]) != count or int(match[2]) <= 0 or footer != [(match[1], match[2])]:
        raise ValueError("missing/duplicate/mismatching native closure")
    io = [line for line in log.splitlines() if line.startswith("tb: M7.3b")]
    if io != ["tb: M7.3b win95 co-sim: 0 IN reads serviced "
              "(0 dev_in available, cursor at 0), 1 OUT writes consumed, "
              "0 port/size desync(s), isa-debug-exit reached"]:
        raise ValueError("missing/duplicate/desynchronized normal I/O closure")
    return dict(result="PASS", case=case, records=count, clocks=int(match[2]),
                actual_return_code=return_code, canonical_faults=0, tf_traps=1)


def grade_golden(trace, log, case, sym, image, generator_code, free_code):
    if generator_code != 0 or free_code != 133:
        raise ValueError("golden requires actual free QEMU133 and generator0")
    count = grade_trace(trace, case, sym, image, "qemu-gdbstub")
    if not log.endswith("\n") or contracts.FATAL.search(log):
        raise ValueError("truncated/fatal golden log")
    footer = re.findall(r"^\[gen_trace\] wrote (\d+) records to [^\r\n]+ "
                        r"\(guest exited, code=0\)$", log, re.MULTILINE)
    if footer != [str(count)]:
        raise ValueError("missing/duplicate/mismatching golden exit footer")
    return count
