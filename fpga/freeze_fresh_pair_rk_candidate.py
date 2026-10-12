"""Export only the checked fresh paired-capture delta with original RK clocks.

Keep full P5 caches, all 158 defines, posted-16 transport and all 190 payloads.
No synthesis, standard-suite or physical pass is inherited from a parent.
"""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('freeze_fp_high_valid_rk_candidate.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '66d4f5f0521518da73518517f93bcb83acb22b6adb21e163b90bfa3777bde820'
end_doc = text.index('"""', 3) + 3
text = repr(__doc__) + text[end_doc:]


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


change('import build_fp_high_valid_soc as native', 'import build_fresh_pair_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = '90e4ec12f6d61699a175484366450a41d67a8d7b1717b3d228f8b5b0ab8bb87c'")
change("old['variant'] == 'pair_now_read_ack_timing'", "old['variant'] == 'read_owner_ack_timing'")
change("native.recipe.transform(before.decode(), name.removeprefix('ventium/'))",
       "native.transformed(before.decode(), name.removeprefix('ventium/'))")
change("variant='fp_high_valid_timing'", "variant='fresh_pair_capture_timing'")
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Fresh current-U paired capture cofactor only; no timing or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__), native.original,')

exec(compile(text, str(Path(__file__)), 'exec'), globals())
