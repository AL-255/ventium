#!/usr/bin/env python3
"""Independent, optimistic P54 adjacent-pair bound for an annotated trace.

This is deliberately not a cycle simulator.  It ignores cache residence,
latency, AGI, prefixes' extra decode clocks, exceptions and branch recovery.
It answers only experiment A in docs/P54_SUB1_CPI_MASTER_PLAN_2026-09-27.md:
how many adjacent instruction pairs are *potentially* legal?  Timing rules
come from Intel AP-500, 241799-001, sections 5.5 and 5.6, not issue_uv.sv.
An absent annotation is an error, never a favorable default.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class Insn:
    # Pairability classification from AP-500 §5.6.2: NP, UV, PU, PV.
    pipe: str
    gpr_reads: int
    gpr_writes: int
    flags_read: bool
    flags_write: bool
    addr_reads: int
    memory: bool
    physical_address: int | None
    # A prefix does not automatically prohibit U pairing (AP-500 §5.5).
    # It does consume decode time, which this optimistic bound omits.
    prefixes: int
    displacement_and_immediate: bool
    special: str | None
    # This is an instruction-instance boundary, not a repeated REP element.
    instance: int
    # Branch/event boundaries separate streams; a pair may not cross them.
    boundary_after: bool

    @classmethod
    def from_json(cls, row: dict) -> "Insn":
        required = {f.name for f in cls.__dataclass_fields__.values()}
        missing = required - row.keys()
        extra = row.keys() - required
        if missing or extra:
            raise ValueError(f"instruction annotation missing={sorted(missing)} extra={sorted(extra)}")
        insn = cls(**row)
        if insn.pipe not in {"NP", "UV", "PU", "PV"}:
            raise ValueError(f"invalid pipe class {insn.pipe!r}")
        if insn.prefixes < 0 or insn.instance < 0:
            raise ValueError("negative prefix count or instruction instance")
        for mask in (insn.gpr_reads, insn.gpr_writes, insn.addr_reads):
            if not isinstance(mask, int) or not 0 <= mask < 256:
                raise ValueError("GPR masks must be unsigned 8-bit")
        if insn.memory != (insn.physical_address is not None):
            raise ValueError("memory instruction needs a physical address")
        if insn.physical_address is not None and not 0 <= insn.physical_address < 2**32:
            raise ValueError("physical address out of range")
        if insn.special not in {None, "cmp_jcc", "add_jne", "push_push", "push_call", "pop_pop"}:
            raise ValueError(f"unknown special-pair classification {insn.special!r}")
        return insn


def pairable(u: Insn, v: Insn) -> bool:
    """AP-500 §5.6 eligibility only; bank conflict delays, not forbids, a pair."""
    if u.boundary_after or u.instance == v.instance:
        return False
    if u.pipe not in {"UV", "PU"} or v.pipe not in {"UV", "PV"}:
        return False
    if u.displacement_and_immediate or v.displacement_and_immediate:
        return False
    # AP-500 §5.6.4 explicitly permits these otherwise dependent pairs.
    special = u.special is not None and u.special == v.special
    stack_special = special and u.special in {"push_push", "push_call", "pop_pop"}
    flag_special = special and u.special in {"cmp_jcc", "add_jne"}
    # The stack exception is confined to the *implicit ESP* contention.
    # It cannot legalize an unrelated GPR RAW/WAW in the same pair.
    ignored_gpr = 1 << 4 if stack_special else 0
    if (v.gpr_reads | v.addr_reads) & u.gpr_writes & ~ignored_gpr:
        return False
    if u.gpr_writes & v.gpr_writes & ~ignored_gpr:
        return False
    if u.flags_write and v.flags_read and not flag_special:
        return False
    return True


def bank_conflict(u: Insn, v: Insn) -> bool:
    """P54 D-cache banks select physical address bits 4:2 (AP-500 §5.6.5)."""
    return bool(u.memory and v.memory and
                ((u.physical_address >> 2) & 7) == ((v.physical_address >> 2) & 7))


def max_adjacent_pairs(trace: Iterable[Insn]) -> tuple[int, int, int]:
    """Maximum non-overlapping pairs on this fixed path, independent of timing.

    A greedy issue scheduler is not an optimistic upper bound: choosing pair
    (i,i+1) may sacrifice pair (i+1,i+2).  This dynamic program considers both.
    """
    insns = list(trace)
    best = [0] * (len(insns) + 2)
    conflict_pairs = [0] * (len(insns) + 2)
    for i in range(len(insns) - 1, -1, -1):
        best[i] = best[i + 1]
        conflict_pairs[i] = conflict_pairs[i + 1]
        if i + 1 < len(insns) and pairable(insns[i], insns[i + 1]):
            candidate = 1 + best[i + 2]
            if candidate > best[i]:
                best[i] = candidate
                conflict_pairs[i] = int(bank_conflict(insns[i], insns[i + 1])) + conflict_pairs[i + 2]
    return len(insns), best[0], conflict_pairs[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jsonl", type=Path, help="one fully annotated x86 instruction instance per line")
    args = parser.parse_args()
    with args.jsonl.open(encoding="utf-8") as src:
        insns = [Insn.from_json(json.loads(line)) for line in src if line.strip()]
    count, pairs, conflicts = max_adjacent_pairs(insns)
    print(json.dumps({"instructions": count, "max_adjacent_pairs": pairs,
                      "min_issue_groups_optimistic": count - pairs,
                      "max_v_slot_fraction": pairs / count if count else 0,
                      "bank_conflicts_in_selected_matching": conflicts,
                      "is_cycle_forecast": False}, sort_keys=True))


if __name__ == "__main__":
    main()
