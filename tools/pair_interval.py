#!/usr/bin/env python3
"""Difference live-issue pairing classifiers; not retirement or saved-cycle counts."""
import argparse
import re

ISSUE = ('V bytes unavailable', 'pairing rule rejected', 'interrupt shadow',
         'debug pair blocked', 'V descriptor unavailable', '16-bit IP wrap',
         'moffs erratum', 'not cycle mode', 'pair allowed')
DENY = ('reserved OK', 'non-simple descriptor', 'pairing class',
        'displacement plus immediate', 'RAW dependency', 'WAW dependency',
        'V memory operand')
PATTERN = re.compile(r'\[VEN-PAIR\] cycle=([0-9]+) issue=([0-9,]+) deny=([0-9,]+)\s*$')


def samples(lines, start=0, end=None):
    first = last = previous = None
    for line in lines:
        if '[VEN-PAIR]' not in line:
            continue
        match = PATTERN.search(line)
        if not match:
            raise ValueError('malformed VEN-PAIR record')
        cycle = int(match[1])
        issue = tuple(map(int, match[2].split(',')))
        deny = tuple(map(int, match[3].split(',')))
        if len(issue) != len(ISSUE) or len(deny) != len(DENY):
            raise ValueError('counter schema changed')
        if deny[0] or sum(deny) != issue[1]:
            raise ValueError('pair rejection counters do not partition the rule-rejected bucket')
        current = (cycle, issue, deny)
        if previous is not None:
            difference(previous, current)
        previous = current
        if cycle >= start and (end is None or cycle <= end):
            if first is None:
                first = current
            last = current
    if first is None or first[0] == last[0]:
        raise ValueError('need two distinct samples in requested interval')
    return first, last


def difference(first, last):
    if last[0] < first[0]:
        raise ValueError('cycle counter decreased')
    deltas = tuple(tuple(b-a for a, b in zip(left, right))
                   for left, right in zip(first[1:], last[1:]))
    if any(value < 0 for family in deltas for value in family):
        raise ValueError('counter decreased')
    if last[0] == first[0] and first != last:
        raise ValueError('conflicting samples at the same cycle')
    if sum(deltas[0]) > last[0]-first[0]:
        raise ValueError('more issue observations than elapsed cycles')
    return deltas


def report(first, last):
    issue, deny = difference(first, last)
    total = sum(issue)
    lines = [f'Actual interval: {first[0]}..{last[0]}',
             f'Live issue-classifier observations: {total}']
    for label, count in zip(ISSUE, issue):
        share = f' ({100*count/total:.2f}% of observations)' if total else ''
        lines.append(f'  {label}: {count}{share}')
    lines.append('Rule-rejected subset (do not add to parent counts):')
    for label, count in zip(DENY[1:], deny[1:]):
        lines.append(f'  {label}: {count}')
    lines.append('Live-descriptor classifiers are not committed packet counts, IPC, or recoverable cycles.')
    return '\n'.join(lines)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('log')
    p.add_argument('--start', type=int, default=0)
    p.add_argument('--end', type=int)
    args = p.parse_args()
    try:
        with open(args.log) as stream:
            print(report(*samples(stream, args.start, args.end)))
    except (OSError, ValueError) as exc:
        p.exit(2, f'PAIR-INTERVAL-ERROR: {exc}\n')


if __name__ == '__main__':
    main()
