"""Freeze one DECODE payload delta and the strict waiting-x87 define at 40 MHz.

Audit all 170 shared HDL inputs and all 190 payloads. Preserve the FPREM
repairs already present in the parent. No timing or acceptance is inherited.
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
change('import build_fp_high_valid_soc as native', 'import build_decode_bus_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = 'f3d9952f0d85d60ce85a85bfec38bb37a939b39a739dc02e6ebde5a6d0297427'")
change("native.recipe.transform(before.decode(), name.removeprefix('ventium/'))",
       'native.recipe.transform(before.decode())')
change('including a fourth source file', 'including any additional source file')
change("old['variant'] == 'pair_now_read_ack_timing'", "old['variant'] == 'branch_address_shape_timing'")
change("started['added_defines'] == []", "started['added_defines'] == [native.FLAG]")
change("len(defs) == len(set(defs)) == 156 and len(hw) == len(set(hw)) == 158",
       "len(defs) == len(set(defs)) == 157 and len(hw) == len(set(hw)) == 158 and native.FLAG not in hw")
change("require(set(hw)-{'SYNTHESIS', 'VTM_NO_DPI'} == set(defs)",
       "require((set(hw)-{'SYNTHESIS', 'VTM_NO_DPI'}) | {native.FLAG} == set(defs)")
change("    actual = [s[2:] for s in started['command']", "    hw = hw[:155]+[native.FLAG]+hw[155:]\n    actual = [s[2:] for s in started['command']")
change("REPO/'fpga/test_rem_split_rk_wrapper.tcl'", "REPO/'fpga/test_strict_mf_rk_wrapper.tcl'")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       "for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),\n"
       "              REPO/'fpga/test_rem_split_rk_wrapper.tcl',")
change("'exact158defs' in done.stdout", "'exact159defs' in done.stdout")
change("variant='fp_high_valid_timing'", "variant='decode_bus_payload_timing'")
change('simulator_defines=156', 'simulator_defines=157, added_defines=[native.FLAG]')
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Strict waiting-x87 policy and DECODE no-request address payload; FPREM repairs retained; no acceptance inherited.'")
exec(compile(text, str(Path(__file__)), 'exec'), globals())
