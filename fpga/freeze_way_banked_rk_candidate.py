"""Freeze the source-matched tag-bank/fetch-page timing candidate at 40 MHz."""
import ast
import hashlib
from pathlib import Path

original=Path(__file__).with_name('freeze_fp_high_valid_rk_candidate.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='66d4f5f0521518da73518517f93bcb83acb22b6adb21e163b90bfa3777bde820'


def change(before,after):
    global text
    assert text.count(before)==1,before
    text=text.replace(before,after)


change('"""'+ast.get_docstring(ast.parse(text),clean=False)+'"""',repr(__doc__))
change('import build_fp_high_valid_soc as native','import build_way_banked_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = '296ff7367ef6af0324c47a09615f09f2c02a700a3de411efc617f598c03c001b'")
change("native.recipe.transform(before.decode(), name.removeprefix('ventium/'))",
       "native.transform(name.removeprefix('ventium/'), before.decode())")
change("old['variant'] == 'pair_now_read_ack_timing'","old['variant'] == 'fp_compare_timing'")
change("variant='fp_high_valid_timing'","variant='way_banked_timing'")
change('including a fourth source file.','including a third source file.')
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Way-banked tags and equivalent fetch-fault page arithmetic; no timing, canonical, standard-suite or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), native.original, Path(native.tags.__file__), Path(native.fetch.__file__), Path(native.fetch.original.__file__),')
exec(compile(text,str(Path(__file__)),'exec'),globals())
