"""Replay all 108 authenticated programs on the four-file composition.

Both old and new models execute the exact retained inputs; require identical
complete state and clocks. This is not new QEMU or canonical qualification.
"""
import ast
import hashlib
from pathlib import Path

import run_pair_next_disjoint_replay as prior


def derive():
    text = prior.derive()
    for old, new in (
        ('pair-next-disjoint-replay-r1', 'fetch-pair-next-replay-r1'),
        ('pair-next-disjoint-core-r1', 'fetch-pair-next-core-r1'),
        ('9beb7023ddfd56888fe6eac6b12ed2feebdbcb7fc367748a989fcb2b63292516',
         '8eaf19eddc32b69549842d52b9b2f5865ea23962d3a520a2a8a660854e1c79d1'),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    anchor = "    pins = dict(started['pins'])"
    path = Path(prior.__file__).resolve()
    assert text.count(anchor) == 1
    text = text.replace(anchor, anchor +
        f'\n    pins[{str(path)!r}]={hashlib.sha256(path.read_bytes()).hexdigest()!r}')
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
