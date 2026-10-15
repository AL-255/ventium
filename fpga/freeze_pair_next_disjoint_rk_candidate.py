"""Freeze the three-file pair/next cofactor with unchanged 40 MHz constraints.

Audit all 170 common HDL inputs, 158 hardware definitions and source closure.
This is an unqualified source export, not a bitstream or acceptance result.
"""
import ast
import hashlib
from pathlib import Path

original=Path(__file__).with_name('freeze_fp_high_valid_rk_candidate.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='66d4f5f0521518da73518517f93bcb83acb22b6adb21e163b90bfa3777bde820'
for old,new in (
    ('"""'+ast.get_docstring(ast.parse(text),clean=False)+'"""',repr(__doc__)),
    ('import build_fp_high_valid_soc as native','import build_pair_next_disjoint_soc as native'),
    ("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
     "PARENT = '9e53127a928b0044465174583cb7ed87abc8da1d7644056054d3ceeeb5688bbb'"),
    ("old['variant'] == 'pair_now_read_ack_timing'","old['variant'] == 'prefix_payload_timing'"),
    ("variant='fp_high_valid_timing'","variant='pair_next_disjoint_timing'"),
    ("note='Wide FP response qualification only; no timing or board pass inherited.'",
     "note='Pair/next lookup exclusion cofactor; preserve pending-U V admission. No canonical, standard-suite, timing or board pass inherited.'"),
    ('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
     'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), native.original, Path(native.recipe.__file__),'),
):
    assert text.count(old)==1,old
    text=text.replace(old,new)
exec(compile(text,str(__file__),'exec'),globals())
