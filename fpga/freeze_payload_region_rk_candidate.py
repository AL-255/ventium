"""Freeze the checked payload-region cut with the unchanged RK hardware profile.

Only L1 and its seam may differ among 190 payloads; all 170 shared HDL inputs
must match the native PC model. No timing, standard-suite or board pass yet.
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
change('import build_fp_high_valid_soc as native','import build_payload_region_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = '034095db8f09866e527046fd6f130a950759f3798c3a72d69bfd53d5756a2c1b'")
change("old['variant'] == 'pair_now_read_ack_timing'","old['variant'] == 'intent_ready_timing'")
change("variant='fp_high_valid_timing'","variant='payload_region_timing'")
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Payload-only aligned-word cache-region hint; no timing or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__), native.original,')
exec(compile(text,str(Path(__file__)),'exec'),globals())
