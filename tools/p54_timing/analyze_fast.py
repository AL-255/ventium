#!/usr/bin/env python3
"""Classify *verified-byte* retires against AP-500, without guessing gaps.

This is a partial-trace diagnostic, not experiment A on the whole gameplay
stream: omitted owners remain explicit gaps. Memory
bank conflicts are unknown until actual physical *data* addresses are traced.
"""

from __future__ import annotations

import argparse
from collections import Counter
import csv
import json
from pathlib import Path

import capstone
from capstone import x86

from pair_bound import Insn, bank_conflict, matching_pairs

DECODERS = {mode: capstone.Cs(capstone.CS_ARCH_X86, mode)
            for mode in (capstone.CS_MODE_16, capstone.CS_MODE_32)}
for decoder in DECODERS.values():
    decoder.detail = True


GPR = {
    alias: bit
    for bit, names in enumerate((
        ("eax", "ax", "al", "ah"), ("ecx", "cx", "cl", "ch"),
        ("edx", "dx", "dl", "dh"), ("ebx", "bx", "bl", "bh"),
        ("esp", "sp", "spl"), ("ebp", "bp", "bpl"),
        ("esi", "si", "sil"), ("edi", "di", "dil"),
    ))
    for alias in names
}
JCC = {"ja", "jae", "jb", "jbe", "jc", "je", "jg", "jge", "jl", "jle",
       "jna", "jnae", "jnb", "jnbe", "jnc", "jne", "jng", "jnge",
       "jnl", "jnle", "jno", "jnp", "jns", "jnz", "jo", "jp", "jpe",
       "jpo", "js", "jz"}
SIMPLE = {"mov", "add", "sub", "and", "or", "xor", "cmp", "inc", "dec", "lea"}
SHIFTS = {"shl", "sal", "shr", "sar", "rol", "ror", "rcl", "rcr"}


def classify(raw: bytes, pc: int, mode16: bool) -> tuple[Insn, str]:
    decoder = DECODERS[capstone.CS_MODE_16 if mode16 else capstone.CS_MODE_32]
    decoded = list(decoder.disasm(raw, pc, count=1))
    if len(decoded) != 1 or decoded[0].size != len(raw):
        raise ValueError(f"byte span does not decode to one instruction at {pc:x}")
    op = decoded[0]
    name = op.mnemonic.lower()
    reads, writes = op.regs_access()

    def mask(registers) -> tuple[int, bool]:
        value, unknown = 0, False
        for register in registers:
            label = op.reg_name(register)
            if label == "eflags" or label in {"eip", "ip"}:
                continue
            if label in GPR:
                value |= 1 << GPR[label]
            else:
                unknown = True
        return value, unknown

    read_mask, unknown_read = mask(reads)
    write_mask, unknown_write = mask(writes)
    addr_mask = 0
    has_memory = False
    special_register = False
    for operand in op.operands:
        if operand.type == x86.X86_OP_MEM:
            for register in (operand.mem.base, operand.mem.index):
                if register:
                    label = op.reg_name(register)
                    if label in GPR:
                        addr_mask |= 1 << GPR[label]
                    else:
                        special_register = True
            has_memory |= name != "lea"
        elif operand.type == x86.X86_OP_REG:
            special_register |= op.reg_name(operand.reg) not in GPR
    prefixes = sum(bool(byte) for byte in op.prefix)
    disp_imm = bool(op.disp_size and op.imm_size)
    forms = tuple(operand.type for operand in op.operands)
    pipe = "NP"
    special = None
    if name in JCC:
        pipe = "PV"
        special = "jne" if name in {"jne", "jnz"} else "jcc"
    elif name in {"jmp", "call"} and forms == (x86.X86_OP_IMM,):
        pipe = "PV"
        if name == "call":
            special = "call"
    elif name in SIMPLE and not special_register:
        pipe = "UV"
        if name in {"cmp", "add"}:
            special = name
    elif name == "test" and not special_register:
        # AP-500 §5.7: reg,reg and accumulator,immediate TEST are one-clock
        # pairable; other TEST forms take two clocks.
        if forms == (x86.X86_OP_REG, x86.X86_OP_REG) or \
           (forms == (x86.X86_OP_REG, x86.X86_OP_IMM) and
            op.reg_name(op.operands[0].reg) in {"eax", "ax", "al"}):
            pipe = "UV"
    elif name in {"adc", "sbb"} and not special_register:
        pipe = "PU"
    elif name in SHIFTS and len(forms) == 2 and forms[1] == x86.X86_OP_IMM and not special_register:
        pipe = "PU"
    elif name in {"push", "pop"} and not special_register:
        if forms == (x86.X86_OP_REG,) or (name == "push" and forms == (x86.X86_OP_IMM,)):
            pipe = "UV"
            special = name
    if prefixes and pipe == "UV":
        pipe = "PU"  # AP-500 §5.5; prefix decode clocks are not modeled here.
    if unknown_read or unknown_write or special_register:
        pipe = "NP"  # No silent pairing on an unmodeled implicit register.
    return Insn(pipe, read_mask, write_mask, x86.X86_REG_EFLAGS in reads,
                x86.X86_REG_EFLAGS in writes, addr_mask, has_memory, None,
                prefixes, disp_imm, special, 0, False), name


def analyze(path: Path, total_legacy: int | None = None) -> dict:
    insns = []
    names = Counter()
    identity = {}
    previous_row = None
    with path.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            ordinal = int(row["legacy_ordinal"])
            pc = int(row["pc"], 16)
            raw = bytes.fromhex(row["bytes"])
            mode16 = int(row["mode16"])
            if mode16 not in (0, 1):
                raise ValueError(f"invalid code mode at ordinal {ordinal}")
            insn, name = classify(raw, pc, bool(mode16))
            bank_field = row.get("data_bank", "")
            data_bank = None if not bank_field else int(bank_field)
            if data_bank is not None and not 0 <= data_bank < 8:
                raise ValueError(f"invalid data bank at ordinal {ordinal}")
            if data_bank is not None and not insn.memory:
                raise ValueError(f"bank on non-memory instruction at ordinal {ordinal}")
            insn = Insn(**{**insn.__dict__, "instance": ordinal,
                           "data_bank": data_bank})
            names["all"] += 1
            names["nonpairable_or_unclassified"] += insn.pipe == "NP"
            names["memory_without_bank_evidence"] += insn.memory and data_bank is None
            if previous_row is not None:
                old_pc, old_len, old_ordinal, old_control = previous_row
                separated = ordinal != old_ordinal + 1 or pc != ((old_pc + old_len) & 0xffffffff)
                if separated or old_control:
                    old = insns[-1]
                    insns[-1] = Insn(**{**old.__dict__, "boundary_after": True})
            insns.append(insn)
            identity[ordinal] = (name, raw.hex()[:2])
            previous_row = (pc, len(raw), ordinal, name in JCC or name in {"jmp", "call", "ret"})
    selected = matching_pairs(insns)
    classes = Counter(("mem" if u.memory else "reg") + "_" +
                      ("mem" if v.memory else "reg") for u, v in selected)
    mem_pair_forms = Counter(
        (identity[u.instance], identity[v.instance])
        for u, v in selected if u.memory and v.memory)
    bank_known = sum(bank_conflict(u, v) is True for u, v in selected)
    bank_unknown = sum(bank_conflict(u, v) is None for u, v in selected)
    count, pairs = len(insns), len(selected)
    result = {"scope": "verified-byte retire subset only", "exported_instructions": count,
              "nonpairable_or_unclassified": names["nonpairable_or_unclassified"],
              "memory_data_bank_unknown": names["memory_without_bank_evidence"],
              "selected_adjacent_pairs_conservative": pairs,
              "selected_pair_classes": {key: classes[key] for key in
                                        ("reg_reg", "reg_mem", "mem_reg", "mem_mem")},
              "top_mem_mem_forms": [
                  {"u": f"{u_name}:{u_op}", "v": f"{v_name}:{v_op}", "pairs": n}
                  for ((u_name, u_op), (v_name, v_op)), n in
                  mem_pair_forms.most_common(20)],
              "selected_bank_conflicts_known": bank_known,
              "selected_bank_conflicts_unknown": bank_unknown,
              "is_full_gameplay_bound": False, "is_cycle_forecast": False}
    if total_legacy is not None:
        result["legacy_retire_events"] = total_legacy
        result["exported_fraction_of_legacy"] = count / total_legacy
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fast_bytes", type=Path)
    parser.add_argument("--legacy-retire-events", type=int)
    args = parser.parse_args()
    print(json.dumps(analyze(args.fast_bytes, args.legacy_retire_events), sort_keys=True))


if __name__ == "__main__":
    main()
