#!/usr/bin/env python3
"""Summarize bounded VENSTATE diagnostics, not architectural .vtrace records.

State numbers are build-specific. EIP is an offset, not a unique physical PC;
different CS/address spaces can alias. ACK is only a sampled signal, not proof
of a memory transaction. These counts do not establish instruction latency.
"""
import argparse
from collections import Counter
import re


LINE = re.compile(
    r'VENSTATE cyc=(\d+) n=(\d+) state=(\d+) eip=([0-9a-fA-F]{8}) '
    r'fx=(\d+) step=(\d+) ack=([01]) addr=([0-9a-fA-F]{8}) '
    r'we=([01]) rsp=(-1|0|1)\s*')
FIELDS = ('cyc', 'n', 'state', 'eip', 'fx', 'step', 'ack', 'addr', 'we', 'rsp')


def records(lines):
    previous = None
    for line in lines:
        start = line.find('VENSTATE ')
        if start < 0:
            continue
        match = LINE.fullmatch(line[start:])
        if not match:
            raise ValueError('malformed VENSTATE record')
        row = {key: int(value, 16 if key in ('eip', 'addr') else 10)
               for key, value in zip(FIELDS, match.groups())}
        if previous is not None:
            if row['cyc'] != previous['cyc'] + 1:
                raise ValueError('nonconsecutive cycles: gap, reset or concatenated capture')
            if row['n'] < previous['n']:
                raise ValueError('retirement count decreased')
        previous = row
        yield row


def summarize(lines, pc=None):
    first = last = None
    states, pcs, by_pc_state = Counter(), Counter(), Counter()
    signals = Counter()
    for row in records(lines):
        if first is None:
            first = row
        last = row
        if pc is not None and row['eip'] != pc:
            continue
        states[row['state']] += 1
        pcs[row['eip']] += 1
        by_pc_state[row['eip'], row['state']] += 1
        signals['ack_high'] += row['ack']
        signals['we_high'] += row['we']
        signals['rsp_high'] += row['rsp'] == 1
        signals['rsp_unavailable'] += row['rsp'] == -1
    if first is None:
        raise ValueError('no VENSTATE records')
    return dict(first=first, last=last, states=states, pcs=pcs,
                by_pc_state=by_pc_state, signals=signals)


def render(result, top=10):
    first, last = result['first'], result['last']
    cycles = last['cyc'] - first['cyc']
    retired = last['n'] - first['n']
    selected = sum(result['states'].values())
    lines = [f"Sample cycles (inclusive): {first['cyc']}..{last['cyc']}",
             f'Selected pre-edge observations: {selected}',
             f'Whole-capture counter interval: {retired} retirements / {cycles} cycles',
             f'Whole-capture IPC: {retired / cycles:.6f}' if cycles else
             'Whole-capture IPC: undefined (one observation)',
             'Build-specific states; EIP offsets may alias across contexts.',
             'Signal-high counts overlap; they are not transaction or stall counts.']
    lines.extend(f'  {name}: {count}' for name, count in sorted(result['signals'].items()))
    for state, count in result['states'].most_common():
        lines.append(f'state={state}: {count} observations ({100 * count / selected:.2f}%)')
    for pc, count in result['pcs'].most_common(top):
        parts = sorted((state, n) for (address, state), n in result['by_pc_state'].items()
                       if address == pc)
        detail = ', '.join(f'{state}:{n}' for state, n in parts)
        lines.append(f'eip={pc:08x}: {count} observations; states {{{detail}}}')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log')
    parser.add_argument('--pc', type=lambda value: int(value, 0),
                        help='filter state counts by EIP offset; IPC still covers the whole capture')
    parser.add_argument('--top', type=int, default=10)
    args = parser.parse_args()
    if args.top < 1 or (args.pc is not None and not 0 <= args.pc <= 0xffffffff):
        parser.error('top must be positive and PC must fit 32 bits')
    try:
        with open(args.log) as stream:
            result = summarize(stream, args.pc)
        print(render(result, args.top))
    except (OSError, ValueError) as exc:
        parser.exit(2, f'STATE-PROFILE-ERROR: {exc}\n')


if __name__ == '__main__':
    main()
