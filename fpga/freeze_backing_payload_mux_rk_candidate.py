"""Export the checked payload-mux derivative with unchanged 40 MHz constraints.

Audit all 170 common HDL inputs, 190 payloads and 158 definitions. This is
UNQUALIFIED source export, not a bitstream, timing result or acceptance pass.
"""
import ast
import hashlib
from pathlib import Path

original = Path(__file__).with_name('freeze_fp_high_valid_rk_candidate.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '66d4f5f0521518da73518517f93bcb83acb22b6adb21e163b90bfa3777bde820'
for old, new in (
    ('"""' + ast.get_docstring(ast.parse(text), clean=False) + '"""', repr(__doc__)),
    ('import build_fp_high_valid_soc as native', 'import build_backing_payload_mux_soc as native'),
    ("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
     "PARENT = '9e53127a928b0044465174583cb7ed87abc8da1d7644056054d3ceeeb5688bbb'"),
    ("old['variant'] == 'pair_now_read_ack_timing'", "old['variant'] == 'prefix_payload_timing'"),
    ("variant='fp_high_valid_timing'", "variant='backing_payload_mux_timing'"),
    ("native.recipe.transform(before.decode(), name.removeprefix('ventium/')).encode()",
     "native.transform(name.removeprefix('ventium/'), before.decode()).encode()"),
    ("note='Wide FP response qualification only; no timing or board pass inherited.'",
     "note='Separate backing address/strobe selection from unchanged late request admission. All-output equivalence including idle hints. No canonical, timing, suite or board pass inherited.'"),
    ('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
     'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), native.original,\n'
     '              Path(native.previous.__file__), Path(native.recipe.__file__),'),
):
    assert text.count(old) == 1, old
    text = text.replace(old, new, 1)
exec(compile(text, str(__file__), 'exec'), globals())
