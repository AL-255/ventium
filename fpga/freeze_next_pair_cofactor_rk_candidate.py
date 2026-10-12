"""Freeze the exact tested RAW hint/pair cofactor, preserving the 40 MHz RK flow.

No port, cache geometry, clock, transport or define change. This remains an
unqualified timing experiment; simulation and parent timing are not acceptance.
"""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('freeze_fp_high_valid_rk_candidate.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '66d4f5f0521518da73518517f93bcb83acb22b6adb21e163b90bfa3777bde820'


def change(old,new):
    global text
    assert text.count(old) == 1,old
    text = text.replace(old,new)


change('import build_fp_high_valid_soc as native','import build_next_pair_cofactor_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = 'd6f856259c0cdef90c0ef3f1a97b0a5568bdba13b8eb9d3a8332fc351bc90c20'")
change("old['variant'] == 'pair_now_read_ack_timing'","old['variant'] == 'backing_pair_payload_timing'")
change("native.recipe.transform(before.decode(), name.removeprefix('ventium/'))",
       "native.transformed(before.decode(), name.removeprefix('ventium/'))")
change("variant='fp_high_valid_timing'","variant='next_pair_cofactor_timing'")
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='RAW next-read/paired-store request cofactor only; no timing or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), Path(__file__).with_name("freeze_fp_high_valid_rk_candidate.py"), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__), native.PROBE,')
exec(compile(text,str(Path(__file__)),'exec'),globals())
