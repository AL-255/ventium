#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Pure closed-artifact fetch-boundary witnesses; import never runs a model."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
SHARED = REPO / "verif/sys/run-pverrw-gate.py"
spec = importlib.util.spec_from_file_location("pfetchbound_contracts", SHARED)
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)
tracefmt = contracts.tracefmt
MAX_INSN = 1800
CASES = {
    1: dict(name="short-call", entry=0x401FFA, pf=0, gp=0, saved=0x401FFF,
            cr2=0, eax=0xDEADC0DE, counter=1,
            head="e801e0ffff", tail="cc", end=0x402001, faults=[]),
    2: dict(name="nop-next-opcode", entry=0x401FFF, pf=1, gp=0, saved=0x402000,
            cr2=0x402000, eax=0xDEADC0DE, counter=1,
            head="90", tail="", end=0x402000, faults=[(14, 4, 0x402000)]),
    3: dict(name="essential-immediate", entry=0x401FFC, pf=1, gp=0, saved=0x401FFC,
            cr2=0x402000, eax=0x2468ACE0, counter=1,
            head="b8e0ac68", tail="24", end=0x402001, faults=[(14, 4, 0x401FFC)]),
    4: dict(name="essential-modrm", entry=0x401FFF, pf=1, gp=0, saved=0x401FFF,
            cr2=0x402000, eax=0x5EEDBEEF, counter=1,
            head="8b", tail="0500400000", end=0x402005, faults=[(14, 4, 0x401FFF)]),
    5: dict(name="essential-sib", entry=0x401FFE, pf=1, gp=0, saved=0x401FFE,
            cr2=0x402000, eax=0x5EEDBEEF, counter=1,
            head="8b04", tail="2500400000", end=0x402005, faults=[(14, 4, 0x401FFE)]),
    6: dict(name="prefix16-nonpresent", entry=0x401FF1, pf=1, gp=1, saved=0x401FF1,
            cr2=0x402000, eax=0xDEADC0DE, counter=0,
            head="2e" * 15, tail="90", end=0x402001,
            faults=[(14, 4, 0x401FF1), (13, 0, 0x401FF1)]),
    7: dict(name="prefix16-present", entry=0x401FF1, pf=0, gp=1, saved=0x401FF1,
            cr2=0, eax=0xDEADC0DE, counter=0,
            head="2e" * 15, tail="90", end=0x402001, faults=[(13, 0, 0x401FF1)]),
    8: dict(name="overrun-immediate-endpoint", entry=0x401FF0, pf=1, gp=1, saved=0x401FF0,
            pf_cr2=0x402000, cr2=0x402000, eax=0xDEADC0DE, counter=0,
            head="2e" * 12 + "b8e0ac68", tail="24", end=0x402001,
            faults=[(14, 4, 0x401FF0), (13, 0, 0x401FF0)]),
    9: dict(name="overrun-displacement-first", entry=0x401FEE, pf=0, gp=1, saved=0x401FEE,
            pf_cr2=0, cr2=0, eax=0xDEADC0DE, counter=0,
            head="2e" * 11 + "3ec70500400000", tail="df9b5713", end=0x402004,
            faults=[(13, 0, 0x401FEE)]),
    10: dict(name="nm-before-modrm", entry=0x401FFF, pf=1, gp=0, nm=1,
             initial_ts=1, final_ts=0, saved=0x401FFF, cr2=0x402000,
             eax=0xDEADC0DE, counter=1, head="d9", tail="e8", end=0x402001,
             x87_store="db3d10400000", counter_pc=0x402007,
             faults=[(7, 0, 0x401FFF), (14, 4, 0x401FFF)]),
    11: dict(name="mov-cr-cpl-before-modrm", entry=0x401FFE, pf=0, gp=1, nm=0,
             initial_ts=0, final_ts=0, saved=0x401FFE, cr2=0,
             eax=0xDEADC0DE, counter=0, head="0f20", tail="c0", end=0x402001,
             faults=[(13, 0, 0x401FFE)]),
    12: dict(name="mov-dr-cpl-before-modrm", entry=0x401FFE, pf=0, gp=1, nm=0,
             initial_ts=0, final_ts=0, saved=0x401FFE, cr2=0,
             eax=0xDEADC0DE, counter=0, head="0f21", tail="c0", end=0x402001,
             faults=[(13, 0, 0x401FFE)]),
    13: dict(name="opcode15-nm-before-overlength", entry=0x401FF1, pf=1, gp=1, nm=1,
             initial_ts=1, final_ts=0, saved=0x401FF1, cr2=0x402000,
             eax=0xDEADC0DE, counter=0, head="2e" * 14 + "d9", tail="e8", end=0x402001,
             faults=[(7, 0, 0x401FF1), (14, 4, 0x401FF1), (13, 0, 0x401FF1)]),
    14: dict(name="opcode16-pf-before-gp-no-nm", entry=0x401FF1, pf=1, gp=1, nm=0,
             initial_ts=1, final_ts=1, saved=0x401FF1, cr2=0x402000,
             eax=0xDEADC0DE, counter=0, head="2e" * 15, tail="d9e8", end=0x402002,
             faults=[(14, 4, 0x401FF1), (13, 0, 0x401FF1)]),
    15: dict(name="opcode16-present-gp-no-nm", entry=0x401FF1, pf=0, gp=1, nm=0,
             initial_ts=1, final_ts=1, saved=0x401FF1, cr2=0,
             eax=0xDEADC0DE, counter=0, head="2e" * 15, tail="d9e8", end=0x402002,
             faults=[(13, 0, 0x401FF1)]),
    16: dict(name="lgdt-cpl-before-sib", entry=0x401FFD, pf=0, gp=1, nm=0,
             initial_ts=0, final_ts=0, saved=0x401FFD, cr2=0,
             eax=0xDEADC0DE, counter=0, head="0f0114", tail="2500400000", end=0x402005,
             faults=[(13, 0, 0x401FFD)]),
    17: dict(name="lmsw-cpl-before-sib", entry=0x401FFD, pf=0, gp=1, nm=0,
             initial_ts=0, final_ts=0, saved=0x401FFD, cr2=0,
             eax=0xDEADC0DE, counter=0, head="0f0134", tail="2500400000", end=0x402005,
             faults=[(13, 0, 0x401FFD)]),
    18: dict(name="lldt-cpl-before-sib", entry=0x401FFD, pf=0, gp=1, nm=0,
             initial_ts=0, final_ts=0, saved=0x401FFD, cr2=0,
             eax=0xDEADC0DE, counter=0, head="0f0014", tail="2500400000", end=0x402005,
             faults=[(13, 0, 0x401FFD)]),
    19: dict(name="lidt-cpl-before-sib", entry=0x401FFD, pf=0, gp=1, nm=0,
             initial_ts=0, final_ts=0, saved=0x401FFD, cr2=0,
             eax=0xDEADC0DE, counter=0, head="0f011c", tail="2500400000", end=0x402005,
             faults=[(13, 0, 0x401FFD)]),
    20: dict(name="smsw-unprivileged-width", entry=0x401FFD, pf=0, gp=0, nm=0,
             initial_ts=0, final_ts=0, saved=0, cr2=0,
             eax=0xDEADC0DE, counter=1, head="0f01e0",
             tail="a308400000660f01e3891d0c400000b8dec0adde", end=0x402014,
             faults=[]),
    21: dict(name="inpage-lgdt-cpl-before-overrun", entry=0x401FF0, pf=0, gp=1, nm=0,
             initial_ts=0, final_ts=0, saved=0x401FF0, cr2=0,
             eax=0xDEADC0DE, counter=0, head="2e" * 11 + "0f01150040",
             tail="0000", end=0x402002, faults=[(13, 0, 0x401FF0)]),
    22: dict(name="inpage-nm-before-unsupported-ud", entry=0x401F00, pf=0, gp=0, nm=1, ud=1,
             initial_ts=1, final_ts=0, saved=0x401F00, cr2=0,
             eax=0xDEADC0DE, counter=0, head="d9d1", tail="", end=0x401F02,
             faults=[(7, 0, 0x401F00), (6, 0, 0x401F00)]),
}


def validate_manifest(manifest):
    if (manifest.get("name"), manifest.get("exit_code"), manifest.get("max_insn"),
            manifest.get("image_bytes")) != ("pfetchbound", 133, MAX_INSN, 65536):
        raise ValueError("unreviewed directed manifest contract")
    expected = [dict(id=case, name=data["name"], entry=f"0x{data['entry']:08x}",
                     faults=[[v, e, f"0x{pc:08x}"] for v, e, pc in data["faults"]],
                     **({"encoding": dict(head=data["head"], tail=data["tail"])} if case == 21 else {}))
                for case, data in CASES.items()]
    if manifest.get("cases") != expected:
        raise ValueError("manifest boundary cases/fault order changed")


def validate_image(case, sym, image):
    data = CASES[case]
    physical = data["entry"] - 0x401000 + 0xF9000
    constants = dict(case_id=case, user_entry_eip=data["entry"],
                     user_entry_physical=physical, expected_pf=data["pf"],
                     expected_gp=data["gp"], expected_final_eax=data["eax"],
                     expected_counter=data["counter"], expected_fault_eip=data["saved"],
                     expected_cr2=data["cr2"], user_safe_eip=0x400000)
    if case >= 10:
        constants.update(expected_nm=data["nm"], expected_initial_ts=data["initial_ts"])
    if case == 22:
        constants["expected_ud"] = data["ud"]
    head, tail = bytes.fromhex(data["head"]), bytes.fromhex(data["tail"])
    x87_store = bytes.fromhex(data.get("x87_store", ""))
    positions = dict(user_safe=0xF8000, user_safe_pop=0xF8000,
                     user_safe_counter=0xF8001, user_safe_int=0xF8007,
                     user_entry=physical, user_entry_end=physical + len(head),
                     user_tail=0xFA000, user_instruction_end=0xFA000 + len(tail),
                     user_counter=0xFA000 + len(tail) + len(x87_store),
                     user_int=0xFA006 + len(tail) + len(x87_store))
    if case == 10:
        positions["user_x87_store"] = 0xFA000 + len(tail)
    elif case == 20:
        positions.update(user_smsw_full_store=0xFA000, user_smsw_word=0xFA005,
                         user_smsw_word_store=0xFA009, user_smsw_restore=0xFA00F)
    elif case == 22:
        positions["user_instruction_end"] = physical + len(head)
    for name, wanted in (constants | positions).items():
        if sym.get(name) != wanted:
            raise ValueError(f"reviewed ELF address/constant changed: {name}")
    if len(image) != 65536:
        raise ValueError("BIOS must be exactly 64KiB")
    start = physical - 0xF0000
    if image[start:start + len(head)] != head:
        raise ValueError("essential page-one bytes changed")
    expected_tail = tail + x87_store + bytes.fromhex("ff0504400000cd40")
    if image[0xA000:0xA000 + len(expected_tail)] != expected_tail:
        raise ValueError("essential page-two bytes/counter/INT40 changed")
    if image[0x8000:0x8009] != bytes.fromhex("5eff0504400000cd40"):
        raise ValueError("safe CALL target return readback/counter/INT40 changed")
    at = sym["set_exit_port"] - 0xF0000
    if (not 0 <= at < 0x8000 or sym["do_out"] != sym["set_exit_port"] + 4
            or image[at:at + 5] != bytes.fromhex("66baf400ee")):
        raise ValueError("ELF/BIOS actual debug-exit path mismatch")


def grade_trace(case, trace, sym, image, producer):
    validate_image(case, sym, image)
    data = CASES[case]
    rows = contracts.validate_trace(trace, producer)
    if len(rows) >= MAX_INSN:
        raise ValueError("directed fixture reached instruction cap")
    pcs = [tracefmt.parse_hex(row["pc"]) for row in rows]
    for name in ("fail_count", "fail_frame", "fail_effect", "fail_unexpected", "unexpected_fault"):
        if sym[name] in pcs:
            raise ValueError(f"guest boundary/frame/effect assertion failed: {name}")
    if (pcs.count(sym["pf_handler"]) != data["pf"]
            or pcs.count(sym["gp_handler"]) != data["gp"]
            or pcs.count(sym["final_grade"]) != 1):
        raise ValueError("wrong exact handler/terminal entry counts")
    if case >= 10 and pcs.count(sym["nm_handler"]) != data["nm"]:
        raise ValueError("wrong exact no-error #NM handler count")
    if case == 22 and pcs.count(sym["ud_handler"]) != data["ud"]:
        raise ValueError("wrong exact no-error #UD handler count")

    def observation(name, register, wanted, mask=0xFFFFFFFF):
        hits = [n for n, pc in enumerate(pcs) if pc == sym[name]]
        if len(hits) != 1:
            raise ValueError(f"missing/duplicate actual architectural readback: {name}")
        n = hits[0]
        if ((tracefmt.parse_hex(rows[n][register]) & mask) != wanted
                or tracefmt.parse_hex(rows[n]["cs"]) != 8
                or tracefmt.parse_hex(rows[n]["ss"]) != 0x10):
            raise ValueError(f"wrong actual frame/effect readback: {name}")
        return n

    nm_positions = []
    if data.get("nm", 0):
        fields = (("eip", "esi", data["entry"]), ("cs", "ecx", 0x1B),
                  ("flags", "ebp", 2), ("cr2", "edi", 0))
        nm_positions = [observation(f"nm_capture_{field}", register, value)
                        for field, register, value in fields]
        nm_positions.append(observation("nm_capture_cr0", "edi", 0x80010009, 0x80010009))
        fields = (("esp", "edx", 0x80000), ("ss", "ebp", 0x23),
                  ("seed", "ebx", 0x5EEDBEEF), ("counter", "ecx", 0),
                  ("eax", "edx", 0xDEADC0DE))
        nm_positions.extend(observation(f"nm_capture_{field}", register, value)
                            for field, register, value in fields)
        if nm_positions != sorted(nm_positions):
            raise ValueError("actual no-error #NM frame/effect readbacks reordered")
        clear = [n for n, pc in enumerate(pcs) if pc == sym["nm_clear_ts"]]
        nm_retries = [n for n, pc in enumerate(pcs) if pc == sym["nm_retry_iret"]]
        if (len(clear) != 1 or len(nm_retries) != 1
                or not nm_positions[-1] < clear[0] < nm_retries[0]
                or tracefmt.parse_hex(rows[clear[0]]["cr0"]) & 8):
            raise ValueError("missing actual CLTS and unchanged-frame #NM IRET retry")

    groups = []
    for kind, enabled, error in (("pf", data["pf"], 4), ("gp", data["gp"], 0)):
        if not enabled:
            continue
        fields = (("error", "ebx", error), ("eip", "esi", data["saved"]),
                  ("cs", "ecx", 0x1B), ("flags", "ebp", 2),
                  ("cr2", "edi", data.get("pf_cr2", 0x402000) if kind == "pf" else data["cr2"]),
                  ("esp", "edx", 0x80000), ("ss", "ebp", 0x23),
                  ("seed", "ebx", 0x5EEDBEEF), ("counter", "ecx", 0),
                  ("eax", "edx", 0xDEADC0DE))
        positions = [observation(f"{kind}_capture_{field}", register, value)
                     for field, register, value in fields]
        if positions != sorted(positions):
            raise ValueError("actual frame/effect readbacks reordered")
        groups.append(positions)
    if len(groups) == 2 and groups[0][-1] >= groups[1][0]:
        raise ValueError("nonpresent essential overrun byte must deliver checked PF before checked GP")
    ud_positions = []
    if data.get("ud", 0):
        fields = (("eip", "esi", data["entry"]), ("cs", "ecx", 0x1B),
                  ("flags", "ebp", 2), ("cr2", "edi", 0),
                  ("esp", "edx", 0x80000), ("ss", "ebp", 0x23),
                  ("seed", "ebx", 0x5EEDBEEF), ("counter", "ecx", 0),
                  ("eax", "edx", 0xDEADC0DE))
        ud_positions = [observation(f"ud_capture_{field}", register, value)
                        for field, register, value in fields]
        if ud_positions != sorted(ud_positions):
            raise ValueError("actual no-error #UD frame/effect readbacks reordered")
    if nm_positions:
        successor = groups[0] if groups else ud_positions
        if not successor or nm_retries[0] >= successor[0]:
            raise ValueError("later checked fault must follow actual #NM CLTS/unchanged IRET")
    if data["pf"]:
        retries = [n for n, pc in enumerate(pcs) if pc == sym["pf_retry_iret"]]
        if len(retries) != 1 or retries[0] <= groups[0][-1]:
            raise ValueError("missing/reordered actual unchanged-frame #PF retry")
        if data["gp"] and retries[0] >= groups[1][0]:
            raise ValueError("overlength GP must follow the real #PF IRET retry")

    # Witness counts use actual post-execution CPL3 states. No records are
    # filtered out of the independently performed full-state differential.
    def executed(pc):
        return [n for n, row in enumerate(rows) if pcs[n] == pc
                and tracefmt.parse_hex(row["cs"]) == 0x1B]

    if data["gp"] or data.get("ud", 0):
        if executed(data["entry"]) or executed(0x402000) or executed(data["end"]):
            raise ValueError("faulting instruction or following code retired")
    else:
        essential = [data["entry"], data["end"]]
        if case == 1:
            essential = [data["entry"], 0x400000, 0x400001]
        elif case == 10:
            essential = [data["entry"], data["end"], data["counter_pc"]]
        elif case == 20:
            essential = [data["entry"], 0x402000, 0x402005, 0x402009, 0x40200F, data["end"]]
        positions = []
        for pc in essential:
            hits = executed(pc)
            if len(hits) != 1:
                raise ValueError("missing/duplicate successfully executed user instruction")
            positions.append(hits[0])
        if positions != sorted(positions):
            raise ValueError("successful user flow reordered")
        if case == 1:
            row = rows[executed(0x400000)[0]]
            if (tracefmt.parse_hex(row["esi"]) != 0x401FFF
                    or tracefmt.parse_hex(row["esp"]) != 0x80000):
                raise ValueError("CALL pushed wrong return PC or failed to restore user ESP")
            if executed(0x401FFF) or executed(0x402000):
                raise ValueError("short CALL fell through to unused successor bytes")
        if case == 2 and executed(data["entry"])[0] >= groups[0][0]:
            raise ValueError("NOP must retire before next FIRST-opcode #PF")
        if data["pf"] and executed(data["end"])[0] <= retries[0]:
            raise ValueError("following counter retired before essential-byte retry")

    if case == 10:
        raw = [observation("final_capture_x87_lo", "ebx", 0),
               observation("final_capture_x87_hi", "edx", 0x80000000),
               observation("final_capture_x87_exponent", "edi", 0x3FFF)]
        if raw != sorted(raw) or raw[0] <= executed(data["counter_pc"])[0]:
            raise ValueError("raw80 1.0 must follow exactly-once FLD1/FSTP/counter")
    elif case == 20:
        prepared = [n for n, pc in enumerate(pcs) if pc == sym["prepare_smsw_cr0"]]
        if len(prepared) != 1 or prepared[0] >= executed(data["entry"])[0]:
            raise ValueError("missing/reordered actual CPL0 CR0 preparation")
        expected = tracefmt.parse_hex(rows[prepared[0]]["edx"])
        observation("prepare_smsw_cr0", "edx", expected)
        if (expected & 0x80010001 != 0x80010001
                or tracefmt.parse_hex(rows[prepared[0]]["cr0"]) != expected):
            raise ValueError("SMSW expectations must come from actual enabled CPL0 CR0")
        merged = 0xA5A50000 | (expected & 0xFFFF)
        full_row = rows[executed(data["entry"])[0]]
        word_row = rows[executed(0x402005)[0]]
        if (tracefmt.parse_hex(full_row["eax"]) != expected
                or tracefmt.parse_hex(full_row["ebx"]) != 0xA5A55A5A
                or tracefmt.parse_hex(word_row["ebx"]) != merged):
            raise ValueError("actual SMSW register widths/upper-half preservation mismatch")
        full = observation("final_capture_smsw_full", "edx", expected)
        word = observation("final_capture_smsw_word", "ebx", merged)
        if not executed(data["end"])[0] < full < word:
            raise ValueError("SMSW raw full/word readbacks must follow successful user flow")
    observation("final_capture_seed", "ebx", 0x5EEDBEEF)
    observation("final_capture_counter", "ebp", data["counter"])
    final = rows[-1]
    if tracefmt.parse_hex(final["pc"]) not in {sym["set_exit_port"], sym["do_out"]}:
        raise ValueError("not the actual successful exit path")
    witnesses = dict(eax=0xC0DE0042, ecx=data["pf"], esi=data["saved"], edi=data["cr2"],
                     ebx=0x5EEDBEEF, ebp=data["counter"], edx=0xC0DE00F4,
                     cs=8, ss=0x10, ds=0x23, es=0x23, cr2=data["cr2"], cr3=0x11000)
    for name, value in witnesses.items():
        if tracefmt.parse_hex(final[name]) != value:
            raise ValueError(f"wrong terminal boundary/retry witness: {name}")
    if tracefmt.parse_hex(final["cr0"]) & 0x80010001 != 0x80010001:
        raise ValueError("fixture must keep PE|PG|WP enabled")
    if case >= 10 and bool(tracefmt.parse_hex(final["cr0"]) & 8) != bool(data["final_ts"]):
        raise ValueError("unexpected terminal CR0.TS change")
    return len(rows)


def grade_native(case, trace, stdout, stderr, sym, image, return_code):
    if return_code != 133:
        raise ValueError("native actual wait must be isa-debug-exit 133")
    count = grade_trace(case, trace, sym, image, "rtl")
    spec = importlib.util.spec_from_file_location(
        "pfetchbound_native_acceptance", REPO / "verif/sys/run-native-system.py")
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    grade = native.grade_native(trace, stdout, stderr, return_code, 133, MAX_INSN)
    faults, states = [], []
    for line in (stdout + stderr).splitlines():
        if "[FAULT]" not in line:
            continue
        match = contracts.check_faultlog.FAULT.fullmatch(line)
        if not match:
            raise ValueError("malformed canonical native fault record")
        faults.append((int(match[1]), int(match[2], 16),
                       int(re.search(r" pc=([0-9a-fA-F]{8}) ", line)[1], 16)))
        states.append(int(re.search(r" state=(\d+) ", line)[1]))
    if faults != CASES[case]["faults"]:
        raise ValueError(f"wrong ordered exact native ordinary faults: {faults!r}")
    return dict(result="PASS", records=count, **{k: v for k, v in grade.items() if k != "records"},
                actual_return_code=return_code, ordinary_faults=faults, delivery_states=states)


def grade_golden(case, trace, log, sym, image, generator_code, free_code):
    if generator_code != 0 or free_code != 133:
        raise ValueError("golden requires actual free QEMU 133 and generator 0")
    count = grade_trace(case, trace, sym, image, "qemu-gdbstub")
    if not log.endswith("\n") or contracts.FATAL.search(log):
        raise ValueError("truncated/fatal golden diagnostics")
    footers = re.findall(r"^\[gen_trace\] wrote (\d+) records to [^\r\n]+ "
                         r"\(guest exited, code=0\)$", log, re.MULTILINE)
    if footers != [str(count)]:
        raise ValueError("golden did not close with the complete guest-exit footer")
    return count
