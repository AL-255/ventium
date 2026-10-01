#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Pure closed-artifact fetch/#PF grader; importing never launches a model."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
SHARED = REPO / "verif/sys/run-pverrw-gate.py"
spec = importlib.util.spec_from_file_location("pfetchpc_closed_contracts", SHARED)
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)
tracefmt = contracts.tracefmt
MAX_INSN = 1800
FAULTS = [(14, 4, 0x00400000), (14, 4, 0x00401FFA)]


def validate_image(sym, image):
    constants = dict(user_first_eip=0x00400000, user_cross_eip=0x00401FFA,
                     first_cr2=0x00400000, cross_cr2=0x00402000)
    physical = dict(user_first=0xF8000, user_first_end=0xF8005,
                    user_first_int=0xF8005, user_cross=0xF9FFA,
                    user_cross_end=0xFA004, user_cross_counter=0xFA004,
                    user_cross_int=0xFA00A)
    for name, wanted in (constants | physical).items():
        if sym.get(name) != wanted:
            raise ValueError(f"reviewed ELF address/constant changed: {name}")
    if len(image) != 65536:
        raise ValueError("BIOS must be exactly64KiB")
    if image[0x8000:0x8007] != bytes.fromhex("b8df9b5713cd40"):
        raise ValueError("first-byte control is not the reviewed MOV/INT40")
    if image[0x9FFA:0xA00C] != bytes.fromhex("c70500400000e0ac6824ff0504400000cd40"):
        raise ValueError("essential-crossing C7/store/counter/INT40 bytes changed")
    at = sym["set_exit_port"] - 0xF0000
    if (not 0 <= at < 0x8000 or sym["do_out"] != sym["set_exit_port"] + 4
            or image[at:at + 5] != bytes.fromhex("66baf400ee")):
        raise ValueError("ELF/BIOS actual debug-exit path mismatch")


def grade_trace(trace, sym, image, producer):
    validate_image(sym, image)
    rows = contracts.validate_trace(trace, producer)
    if len(rows) >= MAX_INSN:
        raise ValueError("directed fixture reached instruction cap")
    pcs = [tracefmt.parse_hex(row["pc"]) for row in rows]
    for name in ("fail_count", "fail_frame", "fail_effect", "fail_signature", "unexpected_fault"):
        if sym[name] in pcs:
            raise ValueError(f"guest precision/effect assertion failed: {name}")
    if pcs.count(sym["pf_handler"]) != 2 or pcs.count(sym["phase_controller"]) != 2:
        raise ValueError("must execute exactly two #PF handlers and two user INT40 handlers")

    observations = []
    for prefix, eip, cr2 in (("first", 0x00400000, 0x00400000),
                             ("cross", 0x00401FFA, 0x00402000)):
        fields = (("error", "ebx", 4), ("eip", "esi", eip), ("cs", "ecx", 0x1B),
                  ("cr2", "edx", cr2), ("esp", "edi", 0x00080000), ("ss", "ebp", 0x23))
        positions = []
        for suffix, register, wanted in fields:
            name = f"{prefix}_capture_{suffix}"
            hits = [n for n, pc in enumerate(pcs) if pc == sym[name]]
            if len(hits) != 1:
                raise ValueError(f"missing/duplicate actual frame readback: {name}")
            n = hits[0]
            if (tracefmt.parse_hex(rows[n][register]) != wanted
                    or tracefmt.parse_hex(rows[n]["cs"]) != 8
                    or tracefmt.parse_hex(rows[n]["ss"]) != 0x10):
                raise ValueError(f"wrong actual frame/CR2 readback: {name}")
            positions.append(n)
        if positions != sorted(positions):
            raise ValueError("frame readbacks reordered")
        observations.append(positions)
    if observations[0][-1] >= observations[1][0]:
        raise ValueError("first-byte control must precede essential-byte crossing")

    for name, register, value in (("cross_capture_seed", "ebx", 0x5EEDBEEF),
                                  ("cross_capture_counter", "ecx", 0)):
        hits = [n for n, pc in enumerate(pcs) if pc == sym[name]]
        if len(hits) != 1 or tracefmt.parse_hex(rows[hits[0]][register]) != value:
            raise ValueError("faulting MOV or following counter committed prematurely")

    # Delivery markers retain the faulting source PC with post-delivery CPL0
    # state. Do not delete/align them. Count only actual post-retry user states
    # here; the canonical full differential below compares EVERY record.
    for pc in (0x00400000, 0x00401FFA, 0x00402004):
        executed = [row for row in rows if tracefmt.parse_hex(row["pc"]) == pc
                    and tracefmt.parse_hex(row["cs"]) == 0x1B]
        if len(executed) != 1:
            raise ValueError("missing/duplicate successfully resumed user instruction")
    final = rows[-1]
    if tracefmt.parse_hex(final["pc"]) not in {sym["set_exit_port"], sym["do_out"]}:
        raise ValueError("not the actual successful exit path")
    witnesses = dict(eax=0xC0DE0042, ecx=2, esi=0x00400000, edi=0x00401FFA,
                     ebx=0x00402000, ebp=3, edx=0xC0DE00F4, cs=8, ss=0x10,
                     ds=0x23, es=0x23, cr2=0x00402000, cr3=0x00011000)
    for name, value in witnesses.items():
        if tracefmt.parse_hex(final[name]) != value:
            raise ValueError(f"wrong terminal fetch/retry witness: {name}")
    if tracefmt.parse_hex(final["cr0"]) & 0x80010001 != 0x80010001:
        raise ValueError("fixture must keep PE|PG|WP enabled")
    return len(rows)


def grade_native(trace, stdout, stderr, sym, image, return_code):
    if return_code != 133:
        raise ValueError("native actual wait must be isa-debug-exit133")
    count = grade_trace(trace, sym, image, "rtl")
    # Existing normal debug-exit acceptance checks full unfiltered rows and
    # independent closed streams, matching stop/retirement/real-I/O footers.
    spec = importlib.util.spec_from_file_location(
        "pfetchpc_native_acceptance", REPO / "verif/sys/run-native-system.py")
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    grade = native.grade_native(trace, stdout, stderr, return_code, 133, MAX_INSN)
    faults = []
    states = []
    for line in (stdout + stderr).splitlines():
        if "[FAULT]" not in line:
            continue
        match = contracts.check_faultlog.FAULT.fullmatch(line)
        if not match:
            raise ValueError("malformed canonical native fault record")
        faults.append((int(match[1]), int(match[2], 16),
                       int(re.search(r" pc=([0-9a-fA-F]{8}) ", line)[1], 16)))
        states.append(int(re.search(r" state=(\d+) ", line)[1]))
    if faults != FAULTS:
        raise ValueError(f"wrong ordered exact native #PF events: {faults!r}")
    return dict(result="PASS", records=count, **{k: v for k, v in grade.items() if k != "records"},
                actual_return_code=return_code, ordinary_faults=faults, delivery_states=states)


def grade_golden(trace, log, sym, image, generator_code, free_code):
    if generator_code != 0 or free_code != 133:
        raise ValueError("golden requires actual free QEMU133 and generator0")
    count = grade_trace(trace, sym, image, "qemu-gdbstub")
    if not log.endswith("\n") or contracts.FATAL.search(log):
        raise ValueError("truncated/fatal golden diagnostics")
    footers = re.findall(r"^\[gen_trace\] wrote (\d+) records to [^\r\n]+ "
                         r"\(guest exited, code=0\)$", log, re.MULTILINE)
    if footers != [str(count)]:
        raise ValueError("golden did not close with the complete guest-exit footer")
    return count
