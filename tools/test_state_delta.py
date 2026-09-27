#!/usr/bin/env python3
"""Validate a synthetic recorder fixture and reject corrupted/truncated streams."""
import gzip
import sys
import tempfile
from pathlib import Path
from state_delta_read import Reader

path = Path(sys.argv[1])
reader = Reader(path)
samples = [(cycle, bytes(state)) for cycle, state in reader.records()]
assert [c for c, _ in samples] == [101, 102, 103, 104]
assert samples[0][1] == samples[1][1]
assert samples[0][1][:4] == b'\x01\0\0\0'
assert samples[0][1][4] == 42 and samples[0][1][-1] == 255
assert samples[2][1][:4] == b'\xff'*4 and samples[2][1][21] == 17
assert samples[-1][1][:4] == bytes(4) and samples[-1][1][4] == 0
raw = gzip.decompress(path.read_bytes())
with tempfile.TemporaryDirectory() as tmp:
    for name, bad in [('truncated', raw[:-1]), ('footer-mismatch', raw[:-1]+b'\0')]:
        target = Path(tmp)/name
        target.write_bytes(gzip.compress(bad))
        try:
            list(Reader(target).records())
        except ValueError:
            pass
        else:
            raise AssertionError(name + ' accepted')
print('STATE-DELTA-TEST-OK (changes, unchanged cycles, array tails, reconstruction, corruption)')
