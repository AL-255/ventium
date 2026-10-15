"""Freeze the early bus payload at unchanged 40 MHz / 159 hardware defines.

Exactly one HDL delta, all 170 shared HDL / 190 payload inputs audited. No
timing, canonical, standard-suite, or physical qualification is inherited.
"""
import ast
import hashlib
from pathlib import Path

original=Path(__file__).with_name('freeze_fp_high_valid_rk_candidate.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='66d4f5f0521518da73518517f93bcb83acb22b6adb21e163b90bfa3777bde820'


def change(old,new):
    global text
    assert text.count(old)==1,old
    text=text.replace(old,new)


change('"""'+ast.get_docstring(ast.parse(text),clean=False)+'"""',repr(__doc__))
change('import build_fp_high_valid_soc as native','import build_early_bus_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = '36908a9d96c4ddca51d143f634acacc85c067bfeb1aaf24833a9eda99fb6a7dc'")
change("native.recipe.transform(before.decode(), name.removeprefix('ventium/'))",'native.recipe.transform(before.decode())')
change('including a fourth source file','including any additional source file')
change("old['variant'] == 'pair_now_read_ack_timing'","old['variant'] == 'decode_bus_payload_timing'")
change('len(defs) == len(set(defs)) == 156 and len(hw) == len(set(hw)) == 158',
       'len(defs) == len(set(defs)) == 157 and len(hw) == len(set(hw)) == 159')
change("REPO/'fpga/test_rem_split_rk_wrapper.tcl'","REPO/'fpga/test_strict_mf_rk_wrapper.tcl'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       "for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),\n"
       "              REPO/'fpga/test_rem_split_rk_wrapper.tcl',")
change("'exact158defs' in done.stdout","'exact159defs' in done.stdout")
change("variant='fp_high_valid_timing'","variant='early_bus_payload_timing'")
change('simulator_defines=156','simulator_defines=157, added_defines=[]')
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Early linear address default; physical overrides and all guards preserved. Strict MF and FPREM fixes retained. No acceptance inherited.'")
exec(compile(text,str(Path(__file__)),'exec'),globals())
