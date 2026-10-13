"""Freeze the audited data-segment size cut at unchanged 40/100 MHz.

One HDL delta from the general-repair parent; no gate or hardware acceptance.
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


change('"""' + ast.get_docstring(ast.parse(text), clean=False) + '"""', repr(__doc__))
change('import build_fp_high_valid_soc as native', 'import build_data_size_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = 'bf2a944dc6aedaa7ec406fdf5c5607c54d707b8cb04fa25ad88b6ba74fac9b93'")
change("native.recipe.transform(before.decode(), name.removeprefix('ventium/'))",
       'native.recipe.transform(before.decode())')
change("old['variant'] == 'pair_now_read_ack_timing'", "old['variant'] == 'fp_general_repairs_timing'")
change("variant='fp_high_valid_timing'", "variant='data_size_timing'")
change('including a fourth source file.', 'including a second source file.')
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Data extent uses its existing per-state size before the fetch-only override; no timing, canonical, standard-suite or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),')
exec(compile(text, str(Path(__file__)), 'exec'), globals())
