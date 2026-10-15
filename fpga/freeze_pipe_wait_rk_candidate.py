"""Freeze only the tested wait cofactor with the unchanged 159-define RK profile.

No route, canonical, standard-suite or physical pass is inherited. The
complete source closure must match the compiled PC and directed core.
"""
import ast
from pathlib import Path

import freeze_demand_size_rk_candidate as predecessor

text = predecessor.text
changes = [
    (repr(predecessor.__doc__), repr(__doc__)),
    ('import build_demand_size_soc as native', 'import build_pipe_wait_soc as native'),
    ("PARENT = '9ec9a00dc8a73884074f6ea5e01ba9925f3725bc90425693b974d38fc061e5e7'",
     "PARENT = 'd35a4b77598c979affbe91bb3e245587e118d0244e271872527b9555115f5315'"),
    ("old['variant'] == 'early_bus_payload_timing'", "old['variant'] == 'demand_size_payload_timing'"),
    ("variant='demand_size_payload_timing'", "variant='pipe_wait_read_ack_timing'"),
    ('Request-independent fetch-width payload; issued extent and all authority preserved. No acceptance inherited.',
     'Read/write wait cofactor; same read completion, fragment suppression and separate store admission. No acceptance inherited.'),
    ('for p in (Path(__file__), original,', 'for p in (Path(__file__), Path(predecessor.__file__), original,'),
]
for old, new in changes:
    assert text.count(old) == 1, old
    text = text.replace(old, new)
original = predecessor.original
ast.parse(text)
exec(compile(text, str(Path(__file__)), 'exec'), globals())
