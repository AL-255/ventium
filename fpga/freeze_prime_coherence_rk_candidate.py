"""Freeze the exact three-header commit cofactor into the unchanged RK profile.

Keep all 190 payloads, 170 shared HDL matches, 158 defines and 40/100 MHz
clock constraints. No standard-suite, timing or hardware pass is inherited.
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
change('import build_fp_high_valid_soc as native', 'import build_prime_coherence_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = '6c60993a794d840af5e97398f7379754a8a4a2a2dc0aeff8ef6f0f582cc18e06'")
change("old['variant'] == 'pair_now_read_ack_timing'", "old['variant'] == 'fp_wide_context_timing'")
change("variant='fp_high_valid_timing'", "variant='prime_coherence_timing'")
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Local pipeline commit and no-memory hint coherence cofactors. No timing or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), native.original,\n'
       '              Path(native.recipe.__file__), Path(native.recipe.local.__file__), Path(native.recipe.hint.__file__),')
exec(compile(text, str(Path(__file__)), 'exec'), globals())
