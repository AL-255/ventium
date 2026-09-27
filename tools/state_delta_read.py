#!/usr/bin/env python3
"""Streaming, lossless reader for VENDLT01; reject truncation and corrupt deltas."""
import argparse
import gzip
import json
import struct
from pathlib import Path


class Reader:
    def __init__(self, path):
        self.file = gzip.open(path, 'rb')
        if self.read(8) != b'VENDLT01':
            raise ValueError('bad trace magic')
        n, self.start, self.count, size = self.unpack('<IQQI')
        if not 0 < n < 1000000 or not 0 < self.count <= 1000000 or size > 1 << 30:
            raise ValueError('invalid header limits')
        self.fields = []
        offset = 0
        for _ in range(n):
            name = self.string()
            typ = self.string()
            length, = self.unpack('<I')
            self.fields.append(dict(name=name, type=typ, size=length, offset=offset))
            offset += length
        if offset != size or len({f['name'] for f in self.fields}) != n:
            raise ValueError('invalid field layout')
        self.state = bytearray(self.read(size))

    def read(self, n):
        data = self.file.read(n)
        if len(data) != n:
            raise ValueError('truncated state-delta file')
        return data

    def unpack(self, fmt):
        return struct.unpack(fmt, self.read(struct.calcsize(fmt)))

    def string(self):
        n, = self.unpack('<I')
        if n > 1 << 20:
            raise ValueError('invalid string length')
        return self.read(n).decode('utf8')

    def records(self):
        """Yield cycle and MUTABLE complete state; copy it if retaining a sample."""
        for index in range(self.count):
            cycle, changes = self.unpack('<QI')
            if cycle != self.start + index + 1 or changes > (len(self.state)+15)//16:
                raise ValueError('invalid cycle or change count')
            last = -16
            for _ in range(changes):
                offset, mask = self.unpack('<IH')
                if offset % 16 or offset <= last or not mask or offset + mask.bit_length() > len(self.state):
                    raise ValueError('invalid delta offset/mask')
                last = offset
                data = iter(self.read(mask.bit_count()))
                for bit in range(mask.bit_length()):
                    if mask & (1 << bit):
                        self.state[offset+bit] = next(data)
            yield cycle, self.state
        if self.read(8) != b'ENDDLT01' or self.unpack('<Q')[0] != self.count:
            raise ValueError('missing completion footer')
        if self.read(len(self.state)) != self.state:
            raise ValueError('terminal reconstruction differs from independently recorded full state')
        if self.file.read(1):
            raise ValueError('trailing data')
        self.file.close()


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('trace', type=Path)
    p.add_argument('--schema', action='store_true', help='print layout only; does not validate records')
    args = p.parse_args()
    reader = Reader(args.trace)
    if args.schema:
        print(json.dumps(reader.fields, indent=2))
    else:
        for _ in reader.records():
            pass
        print(f'STATE-DELTA-READ-OK cycles={reader.count} fields={len(reader.fields)} bytes={len(reader.state)}')
