#!/usr/bin/env python3
"""Emit checked packed fpd_t field offsets for offline state-trace analysis."""
import argparse
import re
from pathlib import Path


def layout(source):
    source = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S)
    matches = re.findall(r'typedef\s+struct\s+packed\s*\{([^{}]*)\}\s*fpd_t\s*;', source)
    if len(matches) != 1:
        raise ValueError('expected one packed fpd_t')
    fields = []
    for declaration in matches[0].split(';'):
        if not declaration.strip():
            continue
        m = re.fullmatch(r'\s*logic\s*(?:\[(\d+):0\])?\s*(\w+)\s*', declaration)
        if not m:
            raise ValueError('unsupported declaration: ' + declaration)
        fields.append((m[2], int(m[1]) + 1 if m[1] else 1))
    if len({name for name, _ in fields}) != len(fields):
        raise ValueError('duplicate field')
    offset = 0
    result = []
    for name, width in reversed(fields):
        result.append((name, offset, width))
        offset += width
    return list(reversed(result))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('package', type=Path)
    args = p.parse_args()
    for row in layout(args.package.read_text()):
        print(*row, sep='\t')
