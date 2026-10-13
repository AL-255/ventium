"""Freeze the exact four-file SMSW/endpoint transfer at unchanged 40/100 MHz.

Reuse all native-source, transport and Tcl contract checks. This publishes an
UNQUALIFIED synthesis candidate, never a hardware or canonical acceptance.
"""
import ast
import hashlib
from pathlib import Path

original=Path(__file__).with_name('freeze_fp_high_valid_rk_candidate.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='66d4f5f0521518da73518517f93bcb83acb22b6adb21e163b90bfa3777bde820'


def change(old,new):
    global text
    assert text.count(old)==1,old
    text=text.replace(old,new)


change('"""'+ast.get_docstring(ast.parse(text),clean=False)+'"""',repr(__doc__))
change('import build_fp_high_valid_soc as native','import build_endpoint_map_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = '3725586f494f96210da1c1f15ef56c614bcd8a3b41dbd042b02ffded7d964cd0'")
change("old['variant'] == 'pair_now_read_ack_timing'","old['variant'] == 'prime_reg_flags_timing'")
change("variant='fp_high_valid_timing'","variant='endpoint_map_timing'")
change('including a fourth source file.','including a fifth source file.')
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='General memory SMSW repair plus exact parallel endpoint-map decode. No timing, canonical, standard-suite or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),\n'
       '              Path(native.recipe.endpoint.__file__), Path(native.recipe.smsw.__file__),')
exec(compile(text,str(Path(__file__)),'exec'),globals())
