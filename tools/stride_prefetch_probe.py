#!/usr/bin/env python3
"""Trace-replay upper-bound probe for page-bounded per-PC line-stride prefetch.

This does not change request timing, cache replacement, or retirement.  A
prediction is credited only when a later observed data miss names the exact
physical line and starts at least --fill-cycles after the prediction.  The
credit is an eligibility witness, never an IPC or saved-cycle estimate.
"""
import argparse
import csv
from collections import Counter, defaultdict
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('events', type=Path)
    parser.add_argument('--fill-cycles', type=int, default=30)
    parser.add_argument('--max-lead', type=int, default=100000)
    args = parser.parse_args()
    if args.fill_cycles < 0 or args.max_lead <= args.fill_cycles:
        parser.error('require 0 <= fill-cycles < max-lead')

    history = {}  # PC -> (last physical line, last stride)
    pending = defaultdict(list)  # predicted line -> [(start cycle, source PC)]
    stats = Counter()
    pc_stats = defaultdict(Counter)
    first_cycle = last_cycle = None
    with args.events.open(newline='') as stream:
        rows = csv.DictReader(stream, delimiter='\t')
        if rows.fieldnames != ['cycle', 'physical_line', 'set', 'kind', 'core_eip']:
            raise ValueError('unexpected miss-event schema')
        for row in rows:
            if int(row['kind']) != 1:
                continue
            cycle = int(row['cycle'])
            line = int(row['physical_line'], 16)
            pc = int(row['core_eip'], 16)
            if line & 31:
                raise ValueError('unaligned demand-miss line')
            if first_cycle is None:
                first_cycle = cycle
            if last_cycle is not None and cycle < last_cycle:
                raise ValueError('miss events out of order')
            last_cycle = cycle
            stats['data_misses'] += 1
            pc_stats[pc]['data_misses'] += 1

            # A prediction from a different earlier miss is useful only if
            # this demand arrives after an assumed entire background fill.
            candidates = pending.pop(line, ())
            if candidates:
                stats['predicted_line_demanded'] += 1
                if any(args.fill_cycles <= cycle - start <= args.max_lead
                       for start, _source in candidates):
                    stats['timely_line_demanded'] += 1
                    for start, source in candidates:
                        if args.fill_cycles <= cycle - start <= args.max_lead:
                            pc_stats[source]['timely_predictions'] += 1
                            break
                else:
                    stats['prediction_too_early_or_late'] += 1

            previous = history.get(pc)
            if previous is not None:
                old_line, old_stride = previous
                stride = line - old_line
                history[pc] = (line, stride)
                if stride and stride == old_stride:
                    next_line = line + stride
                    # Do not predict across a 4 KiB page or 32-bit wrap: a
                    # physical-only predictor must not invent a translation.
                    if (0 <= next_line <= 0xffffffe0 and
                            (next_line >> 12) == (line >> 12)):
                        pending[next_line].append((cycle, pc))
                        stats['predictions'] += 1
                        pc_stats[pc]['predictions'] += 1
                    else:
                        stats['page_or_extent_rejected'] += 1
            else:
                history[pc] = (line, None)

    stats['never_later_missed'] = sum(len(v) for v in pending.values())
    print('metric\tvalue')
    for name, value in sorted(stats.items()):
        print(f'{name}\t{value}')
    print('source_pc\tdata_misses\tpredictions\ttimely_predictions')
    for pc, counts in sorted(pc_stats.items(),
                             key=lambda item: item[1]['timely_predictions'], reverse=True)[:20]:
        print(f'{pc:08x}\t{counts["data_misses"]}\t{counts["predictions"]}\t'
              f'{counts["timely_predictions"]}')


if __name__ == '__main__':
    main()
