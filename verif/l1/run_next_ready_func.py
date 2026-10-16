"""Fresh private-reference functional checks, without canonical gate waivers."""
import inspect
from pathlib import Path
import sys

import prepare_next_ready_cofactor as recipe
from build_next_ready_core import MODEL as PARENT

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'issue_uv'))
import run_v_result_carry_func as previous

MODEL='274f36c65682611be280de39a536cb3fbdb39c22b1d5143ceadfe06f1f457ed5'
REFERENCE=previous.REFERENCE
SOURCE=previous.SOURCE


def main():
    namespace=dict(previous.__dict__,__file__=__file__,previous=previous,
                   recipe=recipe,MODEL=MODEL,PARENT=PARENT)
    text=inspect.getsource(previous.derive).replace('set(range(12,16))','set(range(4,8))').replace(
        'cpu=12+index%4','cpu=4+index%4')
    exec(compile(text,__file__,'exec'),namespace)
    text=inspect.getsource(previous.main)
    for old,new in (
        ('set(range(12,16))','set(range(4,8))'),
        ('sorted(recipe.HASHES)','[recipe.FILE]'),
        ('for n in recipe.HASHES:','for n in [recipe.FILE]:'),
        ('recipe.transform((parent/\'candidate\'/n).read_text(), n)',
         'recipe.transform((parent/\'candidate\'/n).read_text())'),
        ('(Path(__file__), Path(recipe.__file__), SOURCE,',
         '(Path(__file__), Path(recipe.__file__), Path(previous.__file__), SOURCE,'),
    ):
        assert text.count(old)==1,old;text=text.replace(old,new)
    exec(compile(text,__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__':raise SystemExit(main())
