"""Fresh unchanged private-reference corpus for the RAW storage specialization."""
import inspect
from pathlib import Path
import sys

import prepare_raw_prime_storage as recipe
from build_raw_prime_storage_core import MODEL as PARENT

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'fe_pipe'))
import run_sfetch_interior_func as template

MODEL = '41f99bcff8125a2caa7fe768f03f242bed1a43323e4d3a190109167248a34e9b'
REFERENCE, SOURCE, REPO = template.REFERENCE, template.SOURCE, template.REPO


def derive():
    assert template.previous.sha(template.__file__) == 'e8514e1ad2e4a3f8be588f80adec9c68780df05bd10778efca291d89872c9417'
    text = inspect.getsource(template.main)
    for old, new in (
        ("'(Path(__file__), Path(recipe.__file__), Path(previous.__file__), SOURCE,'",
         "'(Path(__file__), Path(recipe.__file__), Path(previous.__file__), Path(template.__file__), SOURCE,'"),
        ('recipe=recipe,MODEL=MODEL,PARENT=PARENT)',
         'recipe=recipe,MODEL=MODEL,PARENT=PARENT,template=template)'),
    ):
        assert text.count(old) == 1
        text = text.replace(old, new)
    return text


def main():
    scope = dict(template.__dict__, __file__=__file__, template=template,
                 recipe=recipe, MODEL=MODEL, PARENT=PARENT)
    exec(compile(derive(), __file__, 'exec'), scope)
    return scope['main']()


if __name__ == '__main__':raise SystemExit(main())
