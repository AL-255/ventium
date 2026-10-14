"""Freeze two cycle-neutral changes with unchanged 40/100 MHz UV-fast profile."""
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
change('import build_fp_high_valid_soc as native', 'import build_fp_compare_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = '09160fa65d1b67dcfd9bc263715c5b73475c04410991a3941e651f3eb59fa7c8'")
change("native.recipe.transform(before.decode(), name.removeprefix('ventium/'))",
       "native.transform(name.removeprefix('ventium/'), before.decode())")
change("old['variant'] == 'pair_now_read_ack_timing'", "old['variant'] == 'window_current_timing'")
change("variant='fp_high_valid_timing'", "variant='fp_compare_timing'")
change('including a fourth source file.', 'including a third source file.')
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Parallel next-line tag comparison and direct FP compare-invalid classifier; no timing, canonical, standard-suite or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), native.original, Path(native.next_tag.__file__), Path(native.classifier.__file__),')
exec(compile(text, str(Path(__file__)), 'exec'), globals())
