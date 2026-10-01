#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Pure closed-artifact checker; importing never launches or evaluates a DUT."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
SHARED = REPO / "verif/sys/run-pverrw-gate.py"
spec = importlib.util.spec_from_file_location("pintstackwrap_closed_contracts", SHARED)
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)
tracefmt = contracts.tracefmt
MAX_INSN = 1000


def variant(case):
    if type(case) is not int or not 1 <= case <= 8:
        raise ValueError("case must be an integer1..8")
    word, stack_b, placement = [(case - 1 >> bit) & 1 for bit in range(3)]
    width = 2 if word else 4
    sp = (0x10000 if stack_b else 0) if placement else 0x1000
    frame = sp - 3 * width
    if not stack_b:
        frame &= 0xFFFF
    high = 0 if stack_b else 0xDEAD0000
    return dict(case_id=case, word_gate=word, stack_b=stack_b,
                wrap_placement=placement, slot_bytes=width,
                initial_esp=high | sp, handler_esp=high | frame,
                frame_ip_lin=frame, frame_cs_lin=frame + width,
                frame_flags_lin=frame + 2 * width,
                guard_before_lin=frame - 4, guard_after_lin=sp,
                expected_frame_flags=0xCD7)


def validate_image(case, sym, image):
    info = variant(case)
    for name, value in info.items():
        if sym.get(name) != value:
            raise ValueError(f"wrong ELF fixture constant {name}")
    for name in ("tested_int3", "int3_end", "frame_handler", "tested_iret",
                 "capture_ip", "capture_cs", "capture_flags", "do_exit",
                 "set_exit_port", "do_out", "fail"):
        if not 0xF0000 <= sym.get(name, -1) < 0xFFFF0:
            raise ValueError(f"missing/out-of-ROM ELF label {name}")
    if len(image) != 65536:
        raise ValueError("BIOS must be exactly64KiB")
    if sym.get("expected_frame_ip") != sym["int3_end"] - 0xF0000:
        raise ValueError("saved IP must be actual post-INT3 segment-relative offset")
    at = sym["tested_int3"] - 0xF0000
    if sym["int3_end"] != sym["tested_int3"] + 1 or image[at] != 0xCC:
        raise ValueError("not the exact reviewed one-byte INT3")
    at = sym["tested_iret"] - 0xF0000
    op = b"\x66\xcf" if info["word_gate"] else b"\xcf"
    if image[at:at + len(op)] != op:
        raise ValueError("IRET operand size is not the interrupt-gate size")
    at = sym["set_exit_port"] - 0xF0000
    if (sym["do_out"] != sym["set_exit_port"] + 4
            or image[at:at + 5] != b"\x66\xba\xf4\x00\xee"):
        raise ValueError("ELF/BIOS native debug-exit path mismatch")
    return info


def grade_trace(trace, case, sym, image, producer):
    info = validate_image(case, sym, image)
    rows = contracts.validate_trace(trace, producer)
    if len(rows) >= MAX_INSN:
        raise ValueError("fixture reached instruction cap")
    positions = {}
    for name in ("tested_int3", "frame_handler", "tested_iret"):
        hits = [i for i, row in enumerate(rows)
                if tracefmt.parse_hex(row["pc"]) == sym[name] - 0xF0000]
        if len(hits) != 1:
            raise ValueError(f"{name} not executed exactly once")
        positions[name] = hits[0]
    if not positions["tested_int3"] < positions["frame_handler"] < positions["tested_iret"]:
        raise ValueError("entry/handler/return execution order mismatch")
    if any(tracefmt.parse_hex(row["pc"]) == sym["fail"] - 0xF0000 for row in rows):
        raise ValueError("in-guest frame/guard failure reached")
    for name, expected_sp in (("tested_int3", info["handler_esp"]),
                              ("tested_iret", info["initial_esp"])):
        row = rows[positions[name]]
        if (tracefmt.parse_hex(row["esp"]) != expected_sp
                or tracefmt.parse_hex(row["cs"]) != 8
                or tracefmt.parse_hex(row["ss"]) != 0x20):
            raise ValueError(f"wrong exact {name} stack/control transition")
    final = rows[-1]
    if tracefmt.parse_hex(final["pc"]) not in {
            sym["set_exit_port"] - 0xF0000, sym["do_out"] - 0xF0000}:
        raise ValueError("final record is not the successful actual exit path")
    witnesses = dict(eax=0x42, ebx=case, ecx=info["handler_esp"],
                     esp=info["initial_esp"], ebp=1, esi=sym["expected_frame_ip"],
                     edi=8, edx=0xF4, cs=8, ss=0x20, ds=0x10, es=0x10,
                     fs=0x10, gs=0x10, cr2=0, cr3=0)
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
    log = stdout + stderr  # Only independently closed regular files, never pipes.
    faults = contracts.check_faultlog.read_counts(log.splitlines(keepends=True))
    if faults:
        raise ValueError(f"legal INT3 delivered faults: {dict(faults)}")
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
        raise ValueError("missing/duplicate/desynchronized I/O closure")
    return dict(result="PASS", case=case, records=count, clocks=int(match[2]),
                actual_return_code=return_code, canonical_faults=0)


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
