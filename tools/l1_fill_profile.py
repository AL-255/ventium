#!/usr/bin/env python3
"""Classify bounded VENL1 observations for the full-P5, EN_L2=0 model.

Reports potential blocked-read opportunities, not transactions, saved cycles,
IPC, or proof that an optional hardware path is correct.
"""
import argparse
from collections import Counter
import sys

HEX = {'addr', 'fill', 'owner'}
BOOL = {'req', 'ack', 'we', 'cacheable', 'hit', 'xline', 'poison', 'bypass', 'flush'}
FIELDS = HEX | BOOL | {'cyc', 'state', 'words'}


def records(lines):
    previous = None
    for line in lines:
        marker = line.find('VENL1 ')
        if marker < 0:
            continue
        parts = line[marker:].split()[1:]
        pairs = [part.split('=') for part in parts]
        if any(len(pair) != 2 for pair in pairs):
            raise ValueError('malformed VENL1 field')
        fields = dict(pairs)
        if fields.keys() != FIELDS or len(pairs) != len(FIELDS):
            raise ValueError('incomplete, duplicated, or unknown VENL1 fields')
        row = {key: int(value, 16 if key in HEX else 10) for key, value in fields.items()}
        if (any(row[key] not in (0, 1) for key in BOOL)
                or any(not 0 <= row[key] <= 0xffffffff for key in HEX)
                or not 0 <= row['state'] <= 3 or not 0 <= row['words'] <= 7
                or row['cyc'] < 0):
            raise ValueError('out-of-range VENL1 signal')
        if previous is not None and row['cyc'] != previous + 1:
            raise ValueError('VENL1 cycles must be consecutive within one run')
        previous = row['cyc']
        yield row


def summarize(lines):
    counts = Counter()
    first = last = None
    for r in records(lines):
        if first is None:
            first = r['cyc']
        last = r['cyc']
        counts['observations'] += 1
        if r['state'] != 1:
            continue
        counts['fill_residency'] += 1
        if not r['req'] or r['we'] or r['ack']:
            continue
        counts['blocked_reads_during_fill'] += 1
        if r['bypass'] or not r['cacheable'] or r['flush'] or r['xline']:
            continue
        # Full P5: 128 sets and 32-byte lines. The raw fill address retains
        # its critical-word offset, so never compare whole addresses as tags.
        same_set = ((r['addr'] >> 5) & 127) == ((r['fill'] >> 5) & 127)
        if not same_set and r['hit']:
            counts['potential_other_set_hit'] += 1
        same_line = r['addr'] >> 5 == r['fill'] >> 5
        # In a cacheable fill fw counts already completed WRAP8 beats. The
        # current edge's backing acknowledgement is deliberately not counted.
        arrived = ((r['addr'] >> 2) - (r['fill'] >> 2)) & 7
        if (same_line and r['addr'] % 4 == 0 and not r['poison']
                and r['addr'] != r['owner'] and arrived < r['words']):
            counts['potential_arrived_fill_word'] += 1
    if first is None:
        raise ValueError('no VENL1 observations (probe unavailable or disabled)')
    return first, last, counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log')
    parser.add_argument('--p5-no-dma', action='store_true', required=True,
                        help='confirm 128 sets, 32-byte lines, EN_L2=0/no external L1D snoop')
    args = parser.parse_args()
    try:
        with open(args.log) as stream:
            first, last, counts = summarize(stream)
        print(f'Observed pre-edge cycles: {first:,}..{last:,}')
        for key in ('observations', 'fill_residency', 'blocked_reads_during_fill',
                    'potential_other_set_hit', 'potential_arrived_fill_word'):
            print(f'{key}: {counts[key]:,}')
        print('Subset counts overlap their parent totals. Potential opportunities are not saved cycles or transactions.')
    except (OSError, ValueError) as error:
        print(f'l1_fill_profile: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
