"""Fresh private-reference corpus for the nine-file ACK derivative.

The exact qualified reference and unchanged worker/comparator are explicit;
this does not replace canonical QEMU or convert its failed result to a pass.
"""
import inspect
from pathlib import Path
import sys

import prepare_system_read_ack as recipe
from build_system_read_ack_core import CHANGES, MODEL as PARENT

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'issue_uv'))
import run_v_result_carry_func as previous

MODEL='005d0f17a3360588d6b67c5f49267db785cb7cc07893ee6a14dc42cafe615aeb'
REFERENCE,SOURCE,REPO=previous.REFERENCE,previous.SOURCE,previous.REPO


def derive_functions():
    assert previous.sha(previous.__file__)=='7d396387f90a0f01d7a38c2c7b07910e3af9bc584b41773046d626b8f09d516b'
    derive=inspect.getsource(previous.derive).replace('set(range(12,16))','set(range(4,8))').replace(
        'cpu=12+index%4','cpu=4+index%4')
    main=inspect.getsource(previous.main)
    for old,new in (
        ('set(range(12,16))','set(range(4,8))'),
        ('sorted(recipe.HASHES)','CHANGES'),
        ('for n in recipe.HASHES:','for n in CHANGES:'),
        ("recipe.transform((parent/'candidate'/n).read_text(), n)",
         "recipe.transform((parent/'candidate'/n).read_text(), n.removeprefix(recipe.PREFIX))"),
        ('(Path(__file__), Path(recipe.__file__), SOURCE,',
         '(Path(__file__), Path(recipe.__file__), Path(previous.__file__), SOURCE,'),
    ):
        assert main.count(old)==1,old
        main=main.replace(old,new)
    return derive+'\n'+main


def main():
    scope=dict(previous.__dict__,__file__=__file__,previous=previous,recipe=recipe,
        MODEL=MODEL,PARENT=PARENT,CHANGES=CHANGES)
    exec(compile(derive_functions(),__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__':raise SystemExit(main())
