#!/usr/bin/env python3
"""Rank cycle gaps ending at retirement groups in a bounded VTM diagnostic.

These are elapsed retirement gaps, NOT isolated instruction execution latency.
Same-cycle U/V retirements share one group and must not double-count cycles.
The initial group's unknown incoming interval is excluded.
"""
import argparse
import collections
import re

LINE = re.compile(r"VTM n=(\d+) ([0-9a-fA-F]+:[0-9a-fA-F]+) .* cyc=(\d+)\s*$")


def summarize(lines):
    stats = collections.defaultdict(lambda: [0, 0, 0])
    previous_n = first_cycle = group_cycle = None
    group = []
    incoming = 0
    records = counted = first_size = 0

    def finish():
        if incoming:
            row = stats[tuple(group)]
            row[0] += incoming
            row[1] += 1
            row[2] = max(row[2], incoming)

    for line in lines:
        if not line.startswith("VTM n="):
            continue
        match = LINE.fullmatch(line)
        if not match:
            raise ValueError("malformed VTM record or missing cycle timestamp")
        n, pc, cycle = int(match[1]), match[2].lower(), int(match[3])
        if previous_n is not None and n != previous_n + 1:
            raise ValueError("nonconsecutive retirement numbers")
        if group_cycle is not None and cycle < group_cycle:
            raise ValueError("cycle timestamp moved backwards")
        previous_n = n
        records += 1
        if first_cycle is None:
            first_cycle = cycle
        if cycle != group_cycle:
            finish()
            incoming = 0 if group_cycle is None else cycle - group_cycle
            group_cycle, group = cycle, []
        group.append(pc)
        if cycle == first_cycle:
            first_size += 1
        else:
            counted += 1
    finish()
    if not counted:
        raise ValueError("need at least two distinct retirement cycles")
    elapsed = group_cycle - first_cycle
    assert sum(row[0] for row in stats.values()) == elapsed
    assert records == counted + first_size
    return records, counted, elapsed, stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace")
    parser.add_argument("--top", type=int, default=30)
    args = parser.parse_args()
    try:
        with open(args.trace) as source:
            records, counted, cycles, stats = summarize(source)
    except ValueError as error:
        parser.error(str(error))
    print(f"records={records} counted={counted} cycles={cycles} IPC={counted/cycles:.6f}")
    print("gap_cycles share groups mean_gap max_gap retirement_PCs")
    for pcs, (gap, groups, maximum) in sorted(stats.items(), key=lambda item: -item[1][0])[:args.top]:
        print(f"{gap} {gap/cycles:.2%} {groups} {gap/groups:.2f} {maximum} {','.join(pcs)}")


if __name__ == "__main__":
    main()
