"""Export only the checked early backing payload and DMA declaration repair.

All common HDL must match the native PC model. Preserve the parent's clocks,
UV/fast profile, full P5 caches, transport depth and source-closure checks.
"""
import hashlib
from pathlib import Path

original=Path(__file__).with_name('freeze_fp_high_valid_rk_candidate.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='66d4f5f0521518da73518517f93bcb83acb22b6adb21e163b90bfa3777bde820'


def change(old,new):
    global text
    assert text.count(old)==1,old
    text=text.replace(old,new)


change('import build_fp_high_valid_soc as native','import build_backing_pair_payload_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = '98c7d92a830568b0aa08417b2ad2444df5b14789e92d86e497cae05552d42887'")
change("old['variant'] == 'pair_now_read_ack_timing'","old['variant'] == 'fp_high_valid_timing'")
change("variant='fp_high_valid_timing'","variant='backing_pair_payload_timing'")
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Early backing payload and DMA control declaration repair only; no timing or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), Path(__file__).with_name("freeze_fp_high_valid_rk_candidate.py"), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__), Path(native.staged.dma_recipe.__file__),')

exec(compile(text,str(Path(__file__)),'exec'),globals())
