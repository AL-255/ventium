"""Freeze all tested repairs at unchanged 40/100 MHz, UV-fast and full P5 L1.

Eight source deltas from the last synthesized endpoint-map image; no new
hardware semantics, mode changes or acceptance inherited from compilation.
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
change('import build_fp_high_valid_soc as native',
       'import build_fp_repair_soc as native\nimport fp_repair_hardware as hardware')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = 'c45c29a6b2ae32fdd34defe85a6922e8560b2ccb9054b5d1563ae773a9040bd1'")
change("CHANGES = ['ventium/'+name for name in native.CHANGES]",
       "CHANGES = ['ventium/'+name for name in hardware.CHANGES]")
change('native.recipe.transform(before.decode(), name.removeprefix(\'ventium/\'))',
       'hardware.transform(before.decode(), name.removeprefix(\'ventium/\'))')
change("old['variant'] == 'pair_now_read_ack_timing'", "old['variant'] == 'endpoint_map_timing'")
change("variant='fp_high_valid_timing'", "variant='fp_general_repairs_timing'")
change('including a fourth source file.', 'including a ninth source file.')
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Composed LMSW, segment extent, obsolete x87, environment and FRNDINT repairs. No timing, canonical, standard-suite or board pass inherited.'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),\n'
       '              Path(hardware.__file__), Path(hardware.lmsw.__file__), Path(hardware.extent.__file__),\n'
       '              Path(hardware.obsolete.__file__), Path(hardware.pc.restore.__file__),\n'
       '              Path(hardware.pc.store.__file__), Path(hardware.pc.rounding.__file__),')
exec(compile(text, str(Path(__file__)), 'exec'), globals())
