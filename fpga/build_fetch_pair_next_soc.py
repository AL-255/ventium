"""Transfer the four-file fetch/pair timing composition to the full PC.

Preserve the audited parent source closure, 156 definitions and single-fill
posted16 transport. This experiment does not waive the canonical gate failure.
"""
import ast
from pathlib import Path
import sys

import build_pair_next_disjoint_soc as prior

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'verif/l1'))
import prepare_fetch_pair_next as recipe

previous, tooling = prior.previous, prior.tooling


def transform(name, source):
    return recipe.transform(source, name)


def derive():
    original, text = prior.derive()
    for old, new in (
        ('9beb7023ddfd56888fe6eac6b12ed2feebdbcb7fc367748a989fcb2b63292516',
         '8eaf19eddc32b69549842d52b9b2f5865ea23962d3a520a2a8a660854e1c79d1'),
        ("proof / 'pair-next-disjoint-core-r1'", "proof / 'fetch-pair-next-core-r1'"),
        ('pair-next-disjoint-regression-audit.json', 'fetch-pair-next-regression-audit.json'),
        ('sim_pair_next_disjoint_', 'sim_fetch_pair_next_'),
        ('original, Path(previous.__file__), Path(recipe.__file__), Path(tooling.__file__),',
         'original, Path(previous.__file__), Path(prior.__file__), Path(recipe.__file__),\n'
         '                 Path(recipe.fetch.__file__), Path(recipe.pair.__file__), Path(tooling.__file__),'),
        ('Three-file transfer prepared;', 'Four-file transfer prepared;'),
    ):
        text = recipe.pair.once(text, old, new)
    ast.parse(text)
    return original, text


original, derived = derive()
exec(compile(derived, str(__file__), 'exec'), globals())
