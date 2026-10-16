"""Unchanged fresh private-reference corpus for the isolated width change."""
import inspect
from pathlib import Path
import sys

import prepare_prime_width_payload as recipe
from build_prime_width_core import MODEL as PARENT

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'fe_pipe'))
import run_sfetch_interior_func as template

MODEL='be6b6973e9ac6dcaf14f262e854deaeaad4248e7d3ff5d82569068dd756b37e8'
REFERENCE,SOURCE,REPO=template.REFERENCE,template.SOURCE,template.REPO


def derive():
    assert template.previous.sha(template.__file__)=='e8514e1ad2e4a3f8be588f80adec9c68780df05bd10778efca291d89872c9417'
    text=inspect.getsource(template.main)
    # Preserve its exact generator/comparator; add this adapter's direct input.
    old="'(Path(__file__), Path(recipe.__file__), Path(previous.__file__), SOURCE,'"
    new="'(Path(__file__), Path(recipe.__file__), Path(previous.__file__), Path(template.__file__), SOURCE,'"
    assert text.count(old)==1
    text=text.replace(old,new)
    old='recipe=recipe,MODEL=MODEL,PARENT=PARENT)'
    assert text.count(old)==1
    return text.replace(old,'recipe=recipe,MODEL=MODEL,PARENT=PARENT,template=template)')


def main():
    scope=dict(template.__dict__,__file__=__file__,template=template,recipe=recipe,MODEL=MODEL,PARENT=PARENT)
    exec(compile(derive(),__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__': raise SystemExit(main())
