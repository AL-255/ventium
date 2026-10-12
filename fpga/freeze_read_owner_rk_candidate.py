"""Export only the tested L1 read-owner ACK delta with original RK clocks.

Unchanged payloads, ports, full P5 caches, 158 defines, posted-16 transport and
the entire source closure remain pinned. No synthesis or board pass inherited.
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


change('import build_fp_high_valid_soc as native', 'import build_read_owner_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = '06a4179627952a02aa8444fe91b2a44d5f1dd11bf1f56c5bd0ff07bc232d7777'")
change("old['variant'] == 'pair_now_read_ack_timing'", "old['variant'] == 'pair_intent_timing'")
change("native.recipe.transform(before.decode(), name.removeprefix('ventium/'))",
       "native.transformed(before.decode(), name.removeprefix('ventium/'))")
change("variant='fp_high_valid_timing'", "variant='read_owner_ack_timing'")
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Current-owner read completion cofactor only; no timing or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__), native.original,')

exec(compile(text, str(Path(__file__)), 'exec'), globals())
