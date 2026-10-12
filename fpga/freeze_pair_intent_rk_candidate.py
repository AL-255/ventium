"""Freeze the source-matched intent arbiter with original 40/100 MHz clocks.

No board-port, cache-size, timing-exception or define changes. Internal intent
ports and the simulation-only overlap probe are checked byte for byte.
"""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('freeze_fp_high_valid_rk_candidate.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '66d4f5f0521518da73518517f93bcb83acb22b6adb21e163b90bfa3777bde820'
end_doc = text.index('"""',3)+3
text = repr(__doc__)+text[end_doc:]


def change(old,new):
    global text
    assert text.count(old) == 1,old
    text = text.replace(old,new)


change('import build_fp_high_valid_soc as native','import build_pair_intent_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = 'd6f856259c0cdef90c0ef3f1a97b0a5568bdba13b8eb9d3a8332fc351bc90c20'")
change("old['variant'] == 'pair_now_read_ack_timing'","old['variant'] == 'backing_pair_payload_timing'")
change("native.recipe.transform(before.decode(), name.removeprefix('ventium/'))",
       "native.transformed(before.decode(), name.removeprefix('ventium/'))")
change("variant='fp_high_valid_timing'","variant='pair_intent_timing'")
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Checked store intent has priority over speculative cache lookup; no timing or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__), Path(native.probe.__file__), native.original, native.PROBE,')
exec(compile(text,str(Path(__file__)),'exec'),globals())
