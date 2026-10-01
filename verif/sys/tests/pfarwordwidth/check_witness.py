#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Pure closed-artifact checks; importing this file never launches a guest."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
SHARED = REPO / "verif/sys/run-pverrw-gate.py"
spec = importlib.util.spec_from_file_location("pfarwordwidth_closed_contracts", SHARED)
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)
tracefmt = contracts.tracefmt
MAX_INSN = 6000


def variant(case):
    if type(case) is not int or not 1 <= case <= 32:
        raise ValueError("case must be an integer1..32")
    number = case - 1
    retf, paged, code_d, stack_b, dword = [(number >> bit) & 1 for bit in range(5)]
    width = 4 if dword else 2
    top = 0x1000 if paged else 0x10000
    base = 0x400000 if paged else 0
    start = top - 2 * width
    high = 0 if stack_b else 0xDEAD0000
    after = (top if stack_b else top & 0xFFFF) if retf else start
    return dict(case_id=case, operation_kind=retf, boundary_kind=paged,
                code_d=code_d, stack_b=stack_b, frame_bytes=width,
                expected_esp=high | after, expected_frame_cs=8 if code_d else 0x18,
                expected_ss=0x20, frame_ip_lin=base + start,
                frame_cs_lin=base + start + width, guard_before_lin=base + start - 4)


def validate_symbols(case, sym):
    wanted = variant(case)
    for name, value in wanted.items():
        if sym.get(name) != value:
            raise ValueError(f"wrong ELF fixture constant {name}: {sym.get(name)} != {value}")
    for name in ("tested_op", "call_resume", "retf_resume", "callee", "do_exit",
                 "set_exit_port", "do_out", "fault_fail32"):
        if not 0xF0000 <= sym.get(name, -1) < 0xFFFF0:
            raise ValueError(f"missing/out-of-ROM ELF label {name}")
    expected_ip = sym["retf_resume" if wanted["operation_kind"] else "call_resume"] - 0xF0000
    if sym.get("expected_frame_ip") != expected_ip:
        raise ValueError("frame return offset is not the selected segment-relative target")
    return wanted


def validate_image(case, sym, image):
    info = validate_symbols(case, sym)
    if len(image) != 65536:
        raise ValueError("BIOS must be exactly64KiB")
    prefix = b"\x66" if (info["frame_bytes"] == 2) == bool(info["code_d"]) else b""
    if info["operation_kind"]:
        expected = prefix + b"\xcb"
    else:
        expected = (prefix + b"\x9a" + (sym["callee"] - 0xF0000).to_bytes(info["frame_bytes"], "little")
                    + info["expected_frame_cs"].to_bytes(2, "little"))
    start = sym["tested_op"] - 0xF0000
    if image[start:start + len(expected)] != expected:
        raise ValueError("BIOS does not contain the exact reviewed far-transfer encoding")
    if sym["call_resume"] != sym["tested_op"] + len(expected):
        raise ValueError("CALL return label is not immediately after the tested instruction")
    port = b"\x66\xba\xf4\x00" if info["code_d"] else b"\xba\xf4\x00"
    offset = sym["set_exit_port"] - 0xF0000
    if (sym["do_out"] != sym["set_exit_port"] + len(port)
            or image[offset:offset + len(port) + 1] != port + b"\xee"):
        raise ValueError("ELF/BIOS native debug-exit path mismatch")
    # CS16 witness loads must NOT truncate absolute addresses (400FFC,
    # 13004,10000). Pin a real address-size override on every memory check.
    if not info["code_d"]:
        for name in ("capture_load_ip", "capture_load_cs", "capture_guard_before",
                     "capture_guard_after", "capture_fault_count"):
            at = sym[name] - 0xF0000
            prefixes = []
            while len(prefixes) < 3 and image[at] in (0x66, 0x67):
                prefixes.append(image[at])
                at += 1
            if prefixes.count(0x67) != 1:
                raise ValueError(f"CS16 witness {name} lacks exact address32 override")
    return info


def grade_trace(trace, case, sym, image, producer):
    info = validate_image(case, sym, image)
    rows = contracts.validate_trace(trace, producer)
    if len(rows) >= MAX_INSN:
        raise ValueError("fixture reached instruction cap")
    pc = sym["tested_op"] - 0xF0000
    if sum(tracefmt.parse_hex(row["pc"]) == pc for row in rows) != 1:
        raise ValueError("tested transfer was not executed exactly once")
    if any(tracefmt.parse_hex(row["pc"]) == sym["fault_fail32"] - 0xF0000 for row in rows):
        raise ValueError("unexpected-fault handler was reached")
    final = rows[-1]
    if tracefmt.parse_hex(final["pc"]) not in {
            sym["set_exit_port"] - 0xF0000, sym["do_out"] - 0xF0000}:
        raise ValueError("final record is not the actual successful exit path")
    witnesses = dict(eax=0x42, ebx=case, ecx=info["expected_esp"], esp=info["expected_esp"],
                     ebp=0, esi=sym["expected_frame_ip"], edi=info["expected_frame_cs"], edx=0xF4)
    for name, value in witnesses.items():
        if tracefmt.parse_hex(final[name]) != value:
            raise ValueError(f"wrong final {name}: {final[name]} != {value:#x}")
    selectors = dict(cs=info["expected_frame_cs"], ss=info["expected_ss"],
                     ds=0x10, es=0x10, fs=0x10, gs=0x10)
    for name, value in selectors.items():
        if tracefmt.parse_hex(final[name]) != value:
            raise ValueError(f"wrong final selector {name}")
    if (tracefmt.parse_hex(final["cr0"]) & 0x80000001 != 1 | (info["boundary_kind"] << 31)
            or tracefmt.parse_hex(final["cr2"]) != 0
            or tracefmt.parse_hex(final["cr3"]) != (0x11000 if info["boundary_kind"] else 0)):
        raise ValueError("wrong final paging/control-register witnesses")
    return len(rows)


def grade_native(trace, stdout, stderr, case, sym, image, return_code):
    if return_code != 133:
        raise ValueError("native actual wait status must be133")
    count = grade_trace(trace, case, sym, image, "rtl")
    for name, log in (("stdout", stdout), ("stderr", stderr)):
        if (log and not log.endswith("\n")) or contracts.FATAL.search(log):
            raise ValueError(f"truncated/fatal native {name}")
    # Concatenation is allowed ONLY after independently closed regular files.
    log = stdout + stderr
    counts = contracts.check_faultlog.read_counts(log.splitlines(keepends=True))
    if counts:
        raise ValueError(f"legal frame-width fixture delivered faults: {dict(counts)}")
    stops = [line for line in log.splitlines() if line.startswith("tb: stop:")]
    match = re.fullmatch(r"tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) "
                         r"after (\d+) retired in (\d+) clocks", stops[0]) if len(stops) == 1 else None
    footers = re.findall(r"^tb: retired (\d+) instructions in (\d+) clocks "
                         r"\(bus: \d+ reads, \d+ writes\)$", log, re.MULTILINE)
    if (not match or int(match[1]) != count or int(match[2]) <= 0
            or footers != [(match[1], match[2])]):
        raise ValueError("missing/duplicate/mismatching native closure")
    io = [line for line in log.splitlines() if line.startswith("tb: M7.3b")]
    if io != ["tb: M7.3b win95 co-sim: 0 IN reads serviced "
              "(0 dev_in available, cursor at 0), 1 OUT writes consumed, "
              "0 port/size desync(s), isa-debug-exit reached"]:
        raise ValueError("missing/duplicate/desynchronized normal I/O closure")
    return dict(result="PASS", case=case, records=count, clocks=int(match[2]),
                actual_return_code=return_code, canonical_faults=0)


def grade_golden(trace, log, case, sym, image, generator_code, free_code):
    if generator_code != 0 or free_code != 133:
        raise ValueError("golden requires actual free QEMU133 and generator0")
    count = grade_trace(trace, case, sym, image, "qemu-gdbstub")
    if not log.endswith("\n") or contracts.FATAL.search(log):
        raise ValueError("truncated/fatal golden log")
    footers = re.findall(r"^\[gen_trace\] wrote (\d+) records to [^\r\n]+ "
                         r"\(guest exited, code=0\)$", log, re.MULTILINE)
    if footers != [str(count)]:
        raise ValueError("missing/duplicate/mismatching golden exit footer")
    return count
