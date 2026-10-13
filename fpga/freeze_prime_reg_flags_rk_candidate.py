"""Export one tested branch-flag cofactor to the exact RK synthesis profile.

Preserve 190 payloads, 170 shared HDL matches, 158 defines and 40/100 MHz
constraints. This remains an unqualified timing experiment, not deployment.
"""
import ast
import hashlib
from pathlib import Path

original=Path(__file__).with_name('freeze_fp_high_valid_rk_candidate.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='66d4f5f0521518da73518517f93bcb83acb22b6adb21e163b90bfa3777bde820'
CHILD='1f677f3cc7cd43ccea0d05edb564296865e58bd354795810383794b8ab0f077a'


def change(old,new):
    global text
    assert text.count(old)==1,old
    text=text.replace(old,new)


change('"""'+ast.get_docstring(ast.parse(text),clean=False)+'"""',repr(__doc__))
change('import build_fp_high_valid_soc as native','import build_prime_reg_flags_soc as native')
change("PARENT = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'",
       "PARENT = 'fd6a1b36862845a096981b2028b4df479b00a9da447c35300834eba8f720cd15'")
change("old['variant'] == 'pair_now_read_ack_timing'","old['variant'] == 'prime_cs_timing'")
change("variant='fp_high_valid_timing'","variant='prime_reg_flags_timing'")
change("note='Wide FP response qualification only; no timing or board pass inherited.'",
       "note='Register-only branch-hint flag cofactor; architectural execution unchanged. No timing or hardware pass inherited.'")
change('including a fourth source file.','including any second source file.')
change("    expected = native.recipe.transform(before.decode(), name.removeprefix('ventium/')).encode()\n"
       "    require(after == expected, 'response transformation differs: '+name)",
       "    require(sha256(before) == native.recipe.PARENTS['core_mem_chain.svh'], 'wrong flag-cofactor parent')\n"
       "    require(sha256(after) == CHILD, 'flag cofactor differs from the tested payload')")
change("    old = js(parent/'input-manifest.json', PARENT)",
       "    old = js(parent/'input-manifest.json', PARENT)\n"
       "    inputs={n:read(parent/'ventium/rtl/core'/n)['data'].decode() for n in native.recipe.PARENTS}\n"
       "    require(sha256(native.recipe.transform(inputs).encode()) == CHILD, 'six-source flag contract drift')")
change('for p in (Path(__file__), Path(previous.__file__), Path(native.__file__), Path(native.recipe.__file__),',
       'for p in (Path(__file__), original, Path(previous.__file__), Path(native.__file__), native.original, Path(native.recipe.__file__),')
exec(compile(text,str(Path(__file__)),'exec'),globals())
