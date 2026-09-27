#!/usr/bin/env python3
"""Estimate L2 reuse from cacheable L1 fill starts or miss-event traces.

This is a capacity sensitivity probe, NOT a model of the ao486 L2: stores,
split commands, bypasses and non-L1 requesters are absent. A simulated hit is
not a saved clock, and the 32 KiB row need not equal hardware L2 counters.
"""
import argparse
import csv
from collections import Counter

from l1_fill_profile import records


def fill_lines(rows):
    previous_state = None
    for row in rows:
        if previous_state is not None and previous_state != 1 and row['state'] == 1:
            if not row['bypass']:
                yield row['fill'] >> 6  # ao486 L2 has eight 64-bit beats/line
        previous_state = row['state']


def miss_event_lines(stream):
    """Consume actual L1 demand misses from a state-delta miss-event TSV.

    Kind 2 is a rejected next-lookup, not an issued fill. Kinds 0 and 1
    correspond to instruction- and data-origin demand misses respectively.
    """
    rows = csv.DictReader(stream, delimiter='\t')
    if rows.fieldnames != ['cycle', 'physical_line', 'set', 'kind', 'core_eip']:
        raise ValueError('unexpected miss-event schema')
    previous_cycle = -1
    for row in rows:
        if None in row or any(value is None for value in row.values()):
            raise ValueError('malformed miss-event row')
        try:
            cycle = int(row['cycle'])
            line = int(row['physical_line'], 16)
            set_index = int(row['set'])
            kind = int(row['kind'])
            int(row['core_eip'], 16)
        except (TypeError, ValueError) as error:
            raise ValueError('malformed miss-event row') from error
        if (cycle <= previous_cycle or line < 0 or line > 0xffffffe0 or
                line & 31 or set_index != ((line >> 5) & 127) or
                kind not in (0, 1, 2)):
            raise ValueError('invalid or unordered miss-event row')
        previous_cycle = cycle
        if kind != 2:
            yield line >> 6  # 64-byte hypothetical L2 line


def reuse_counts(lines, capacities=(32, 64, 128, 256), ways=4):
    """Return LRU hit/miss counts for KiB capacities at fixed 64-byte lines."""
    banks = {}
    result = {}
    for kib in capacities:
        if kib <= 0 or (kib * 1024) % (64 * ways):
            raise ValueError('capacity must contain a whole number of sets')
        banks[kib] = [[] for _ in range(kib * 1024 // (64 * ways))]
        result[kib] = Counter()
    for line in lines:
        for kib, sets in banks.items():
            way = sets[line % len(sets)]
            if line in way:
                result[kib]['hits'] += 1
                way.remove(line)
            else:
                result[kib]['misses'] += 1
                if len(way) == ways:
                    way.pop(0)
            way.append(line)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace')
    parser.add_argument('--miss-events', action='store_true',
                        help='read state-delta miss_events.tsv instead of VENL1 observations')
    args = parser.parse_args()
    try:
        with open(args.trace, newline='') as stream:
            lines = miss_event_lines(stream) if args.miss_events else fill_lines(records(stream))
            counts = reuse_counts(lines)
    except (OSError, ValueError) as error:
        parser.exit(2, f'L2-REUSE-ERROR: {error}\n')
    for kib, row in counts.items():
        total = row['hits'] + row['misses']
        rate = row['misses'] / total if total else 0
        print(f'{kib:3d} KiB, 4-way: fills={total} hits={row["hits"]} '
              f'misses={row["misses"]} miss_fraction={rate:.4f}')
    print('L1-demand-stream estimate only; not actual L2 traffic or predicted IPC.')


if __name__ == '__main__':
    main()
