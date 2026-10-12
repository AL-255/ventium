"""Freeze the tested intent-only pair readiness cut with original RK clocks.

Only L1 and its seam may change among 190 payloads. All 170 common HDL inputs
must match the PC model. Full P5 caches, 158 defines and transport stay intact.
No canonical, standard-suite, timing or physical pass is inherited.
"""
import ast
import hashlib
from pathlib import Path

original = Path(__file__).with_name('freeze_fp_high_valid_rk_candidate.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '66d4f5f0521518da73518517f93bcb83acb22b6adb21e163b90bfa3777bde820'


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


change('"""'+ast.get_docstring(ast.parse(text), clean=False)+'"""', repr(__doc__))
change('import build_fp_high_valid_soc as native', 'import build_intent_ready_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = '0c767b0435e78a86aa0f61907dff21f9a2184aedea071d209a1230eb10e4ced7'")
change("old['variant'] == 'pair_now_read_ack_timing'", "old['variant'] == 'fresh_pair_capture_timing'")
change("variant='fp_high_valid_timing'", "variant='intent_ready_timing'")
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Intent-qualified pair readiness only; no timing or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__), native.original,')

exec(compile(text, str(Path(__file__)), 'exec'), globals())
