"""Fresh 108-program private-reference replay, preserving canonical failures."""
import inspect
from pathlib import Path
import sys

import prepare_sfetch_boundary_stage as recipe
from run_sfetch_beat_stage_leaf import sha

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/issue_uv'))
import run_v_result_carry_func as previous

MODEL = 'e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a'


def main():
    # Only models/source closure and disjoint CPU placement differ. The original
    # worker, full-state comparator, oracle and optional manifest masks remain.
    namespace = dict(previous.__dict__, __file__=__file__, previous=previous,
                     recipe=recipe, MODEL=MODEL, PARENT=previous.MODEL)
    text = inspect.getsource(previous.derive).replace('set(range(12,16))','set(range(20,24))').replace(
        'cpu=12+index%4','cpu=20+index%4')
    exec(compile(text,__file__,'exec'),namespace)
    text = inspect.getsource(previous.main)
    text = text.replace('set(range(12,16))','set(range(20,24))').replace('recipe.HASHES','recipe.PARENTS')
    text = recipe.replace_once(text, '(Path(__file__), Path(recipe.__file__), SOURCE,',
        '(Path(__file__), Path(recipe.__file__), Path(recipe.base.__file__), Path(previous.__file__), SOURCE,')
    exec(compile(text,__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__':
    raise SystemExit(main())
