"""Freeze the tested demand-width payload without changing the 159-define RK profile.

One HDL delta; no routed timing, canonical gate or physical pass is inherited.
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
change('import build_fp_high_valid_soc as native', 'import build_demand_size_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = '9ec9a00dc8a73884074f6ea5e01ba9925f3725bc90425693b974d38fc061e5e7'")
change("native.recipe.transform(before.decode(), name.removeprefix('ventium/'))", 'native.recipe.transform(before.decode())')
change('including a fourth source file', 'including any additional source file')
change("old['variant'] == 'pair_now_read_ack_timing'", "old['variant'] == 'early_bus_payload_timing'")
change('len(defs) == len(set(defs)) == 156 and len(hw) == len(set(hw)) == 158',
       'len(defs) == len(set(defs)) == 157 and len(hw) == len(set(hw)) == 159')
change("REPO/'fpga/test_rem_split_rk_wrapper.tcl'", "REPO/'fpga/test_strict_mf_rk_wrapper.tcl'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       "for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),\n"
       "              REPO/'fpga/test_rem_split_rk_wrapper.tcl',")
change("'exact158defs' in done.stdout", "'exact159defs' in done.stdout")
change("variant='fp_high_valid_timing'", "variant='demand_size_payload_timing'")
change('simulator_defines=156', 'simulator_defines=157, added_defines=[]')
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Request-independent fetch-width payload; issued extent and all authority preserved. No acceptance inherited.'")
exec(compile(text, str(Path(__file__)), 'exec'), globals())
