"""Freeze the proved boundary-fetch extent cofactor at the 40 MHz target.

Require the source-matched PC build and unchanged hardware profile. Export is
UNQUALIFIED: no route, standard-suite or physical-board pass is inherited.
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
change('import build_fp_high_valid_soc as native', 'import build_fetch_fragment_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = '9e53127a928b0044465174583cb7ed87abc8da1d7644056054d3ceeeb5688bbb'")
change("native.recipe.transform(before.decode(), name.removeprefix('ventium/'))",
       "native.transform(name.removeprefix('ventium/'), before.decode())")
change("old['variant'] == 'pair_now_read_ack_timing'", "old['variant'] == 'prefix_payload_timing'")
change("variant='fp_high_valid_timing'", "variant='fetch_fragment_timing'")
change('including a fourth source file.', 'including a second source file.')
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Boundary-fetch extent isolation only; no canonical, standard-suite, timing or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), native.original, Path(native.recipe.__file__),')
exec(compile(text, str(Path(__file__)), 'exec'), globals())
