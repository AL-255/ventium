"""Export the exact single-file CS-request cofactor to the unchanged RK profile.

Preserve 190 payloads, 170 shared HDL matches, 158 definitions, 40/100 MHz
constraints and full P5 caches. This is not a timing or hardware pass.
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
change('import build_fp_high_valid_soc as native', 'import build_prime_cs_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = 'e04980eab0ad9131f4434a8804e71f2627b62cb66214b45a5f6f7aed8bb886d2'")
change("old['variant'] == 'pair_now_read_ack_timing'", "old['variant'] == 'prime_coherence_timing'")
change("variant='fp_high_valid_timing'", "variant='prime_cs_timing'")
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='New-memory CS-extent cofactor; global faults and held packets unchanged. No timing or board pass inherited.'")
change('including a fourth source file.', 'including any second source file.')
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), native.original,\n'
       '              Path(native.recipe.__file__), Path(native.recipe.cofactor.__file__),')
exec(compile(text, str(Path(__file__)), 'exec'), globals())
