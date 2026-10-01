#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Closed POP/write-watchpoint witnesses; importing never launches a DUT."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
SHARED = REPO / "verif/sys/run-pverrw-gate.py"
spec = importlib.util.spec_from_file_location("ppopwatch_closed_contracts", SHARED)
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)
tracefmt = contracts.tracefmt
MAX_INSN = 1000


def variant(case):
    if type(case) is not int or case not in (1, 2, 3, 4):
        raise ValueError("case must be integer 1..4")
    destination = 0x24000 if case == 2 else 0x4000 if case == 3 else 0x14000
    return dict(case_id=case, destination_linear=destination,
                watch_linear=0x4000 if case == 4 else destination,
                expected_value=0xD00D1122 if case == 2 else 0x11223344,
                operand_width=2 if case == 2 else 4,
                expected_handlers=0 if case == 4 else 1,
                expected_dr6=0xFFFF0FF0 if case == 4 else 0xFFFF0FF1,
                captured_esp=0x7000 if case == 4 else 0x6FF4,
                postpop_esp=0x7000, expected_saved_flags=2)


def validate_image(case, sym, image):
    info = variant(case)
    for name, value in info.items():
        if sym.get(name) != value:
            raise ValueError(f"wrong ELF fixture constant {name}")
    for name in ("pm32_entry", "tested_op", "tested_end", "db_handler", "capture_ip",
                 "capture_cs", "capture_flags", "capture_dr6", "tested_iret",
                 "do_exit", "set_exit_port", "do_out", "fail"):
        if not 0xF0000 <= sym.get(name, -1) < 0xFFFF0:
            raise ValueError(f"missing/out-of-ROM ELF label {name}")
    if len(image) != 65536:
        raise ValueError("BIOS must be exactly 64KiB")
    if sym.get("expected_frame_ip") != sym["tested_end"]:
        raise ValueError("saved next IP must be absolute in the actual flat CS")
    opcode = b"\x66\x8f\x03" if case == 2 else b"\x8f\x45\x00" if case == 3 else b"\x64\x8f\x03"
    at = sym["tested_op"] - 0xF0000
    if image[at:at + len(opcode)] != opcode or sym["tested_end"] != sym["tested_op"] + len(opcode):
        raise ValueError("not the exact reviewed non-ESP POP memory instruction")
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
    names = ("tested_op", "db_handler", "capture_ip", "capture_cs", "capture_flags",
             "capture_dr6", "tested_iret", "tested_end") if case != 4 else ("tested_op", "tested_end")
    positions = {}
    delivery_marker = None
    for name in names:
        hits = [i for i, row in enumerate(rows) if tracefmt.parse_hex(row["pc"]) == sym[name]]
        if name == "db_handler":
            # The existing producer contract retains both the #DB delivery
            # marker and execution of the handler's first MOV at the same PC.
            # Preserve both rows in the full differential, never trim one.
            if (len(hits) != 2 or hits[0] != positions["tested_op"] + 1
                    or hits[1] != hits[0] + 1):
                raise ValueError("require adjacent #DB delivery marker and first handler instruction")
            delivery_marker, positions[name] = hits
            continue
        if len(hits) != 1:
            raise ValueError(f"{name} must execute exactly once")
        positions[name] = hits[0]
    if any(positions[a] >= positions[b] for a, b in zip(names, names[1:])):
        raise ValueError("POP/trap/handler/return execution order mismatch")
    if positions["tested_op"] == 0:
        raise ValueError("missing actual pre-POP setup")
    before = rows[positions["tested_op"] - 1]
    if (tracefmt.parse_hex(before["esp"]) != 0x7000 - info["operand_width"]
            or tracefmt.parse_hex(before["eflags"]) != 2
            or tracefmt.parse_hex(before["ebx"]) != 0x4000
            or tracefmt.parse_hex(before["ebp"]) != 0x4000
            or tracefmt.parse_hex(before["ecx"]) != 0
            or tracefmt.parse_hex(before["cs"]) != 8
            or tracefmt.parse_hex(before["ss"]) != 0x10
            or tracefmt.parse_hex(before["fs"]) != 0x18
            or tracefmt.parse_hex(before["ds"]) != (0x20 if case == 2 else 0x10)):
        raise ValueError("wrong pre-POP source ESP, base register, flags or segment setup")
    if any(tracefmt.parse_hex(row["pc"]) == sym["fail"] for row in rows):
        raise ValueError("in-guest write/frame/debug self-check failed")
    if case == 4:
        forbidden = {sym[name] for name in ("db_handler", "capture_ip", "capture_cs",
                                           "capture_flags", "capture_dr6", "tested_iret")}
        if any(tracefmt.parse_hex(row["pc"]) in forbidden for row in rows):
            raise ValueError("unwatched real destination must not trap at old SS alias")
    else:
        for index in (positions["tested_op"], delivery_marker, positions["db_handler"]):
            row = rows[index]
            if (tracefmt.parse_hex(row["esp"]) != 0x6FF4
                    or tracefmt.parse_hex(row["cs"]) != 8
                    or tracefmt.parse_hex(row["ss"]) != 0x10
                    or tracefmt.parse_hex(row["eflags"]) != 2):
                raise ValueError("wrong completed-POP trap frame or live TF/RF/VM state")
        keys = tracefmt.GPR_KEYS + tracefmt.SEG_KEYS + tracefmt.SYS_CR + ["eflags"]
        pop, marker, entry = (rows[positions["tested_op"]], rows[delivery_marker],
                              rows[positions["db_handler"]])
        if tracefmt.parse_hex(pop["ecx"]) != 0 or tracefmt.parse_hex(marker["ecx"]) != 0:
            raise ValueError("delivery marker executed the first MOV or changed pre-handler ECX")
        for key in keys:
            if tracefmt.parse_hex(marker[key]) != tracefmt.parse_hex(pop[key]):
                raise ValueError(f"delivery marker changed architectural {key}")
            expected = 0x6FF4 if key == "ecx" else tracefmt.parse_hex(marker[key])
            if tracefmt.parse_hex(entry[key]) != expected:
                raise ValueError(f"first handler MOV has wrong exact {key} effect")
        for name, key, value in (("capture_ip", "edi", sym["tested_end"]),
                                 ("capture_cs", "edx", 8),
                                 ("capture_flags", "ebp", 2),
                                 ("capture_dr6", "esi", info["expected_dr6"])):
            if tracefmt.parse_hex(rows[positions[name]][key]) != value:
                raise ValueError(f"wrong actual saved frame/debug readback {name}")
        if tracefmt.parse_hex(rows[positions["tested_iret"]]["esp"]) != 0x7000:
            raise ValueError("IRET did not resume with completed POP ESP")
    for name in ("tested_end",) if case != 4 else ("tested_op", "tested_end"):
        row = rows[positions[name]]
        if (tracefmt.parse_hex(row["esp"]) != 0x7000
                or tracefmt.parse_hex(row["eflags"]) & 0x34100):
            raise ValueError("wrong post-POP ESP or spurious live TF/RF/VM")
    final = rows[-1]
    if tracefmt.parse_hex(final["pc"]) not in {sym["set_exit_port"], sym["do_out"]}:
        raise ValueError("final record is not successful actual exit path")
    witnesses = dict(eax=0x42, ebx=case, ecx=info["captured_esp"], esp=0x7000,
                     ebp=info["expected_handlers"], esi=info["expected_dr6"],
                     edi=0 if case == 4 else sym["tested_end"], edx=0xF4,
                     cs=8, ss=0x10, ds=0x20 if case == 2 else 0x10,
                     es=0x10, fs=0x18, gs=0x10, cr2=0, cr3=0)
    for name, value in witnesses.items():
        if tracefmt.parse_hex(final[name]) != value:
            raise ValueError(f"wrong final witness {name}")
    if tracefmt.parse_hex(final["cr0"]) & 0x80000001 != 1:
        raise ValueError("fixture must remain protected and unpaged")
    return len(rows)


def grade_native(trace, stdout, stderr, case, sym, image, return_code):
    if type(return_code) is not int or return_code != 133:
        raise ValueError("native actual wait status must be 133")
    count = grade_trace(trace, case, sym, image, "rtl")
    for name, text in (("stdout", stdout), ("stderr", stderr)):
        if (text and not text.endswith("\n")) or contracts.FATAL.search(text):
            raise ValueError(f"truncated/fatal native {name}")
    log = stdout + stderr  # Already closed regular files, never live pipes.
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
                actual_return_code=return_code, canonical_faults=0,
                write_watchpoint_traps=variant(case)["expected_handlers"])


def grade_golden(trace, log, case, sym, image, generator_code, free_code):
    if type(generator_code) is not int or type(free_code) is not int or generator_code != 0 or free_code != 133:
        raise ValueError("golden requires actual free QEMU 133 and generator 0")
    count = grade_trace(trace, case, sym, image, "qemu-gdbstub")
    if not log.endswith("\n") or contracts.FATAL.search(log):
        raise ValueError("truncated/fatal golden log")
    footer = re.findall(r"^\[gen_trace\] wrote (\d+) records to [^\r\n]+ "
                        r"\(guest exited, code=0\)$", log, re.MULTILINE)
    if footer != [str(count)]:
        raise ValueError("missing/duplicate/mismatching golden exit footer")
    return count
