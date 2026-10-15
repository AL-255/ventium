"""Transfer the checked pair/next cofactor into the frozen full-PC model.

Three exact shared-source deltas; no feature, transport, or cache changes.
This is still an unqualified timing experiment, not hardware acceptance.
"""
import ast
from pathlib import Path
import sys

import build_fetch_fragment_soc as previous

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'verif/l1'))
import prepare_pair_next_disjoint as recipe

tooling=previous.tooling


def transform(name,source):
    return recipe.transform(source,name)


def derive():
    original,text=previous.derive()
    for old,new in (
        ('CHANGES = [recipe.FILE]','CHANGES = sorted(recipe.PARENTS)'),
        (tooling.MODEL,'9beb7023ddfd56888fe6eac6b12ed2feebdbcb7fc367748a989fcb2b63292516'),
        ("proof / 'fetch-fragment-core-r1'","proof / 'pair-next-disjoint-core-r1'"),
        ('fetch-fragment-regression-audit.json','pair-next-disjoint-regression-audit.json'),
        ('sim_fetch_fragment_','sim_pair_next_disjoint_'),
        ('tooling_deltas = tooling.qualify_tooling(pins)',
         'tooling_deltas = {}  # Direct current closure; no ancestral tool-pin migration.'),
        ('original, Path(recipe.__file__), Path(tooling.__file__),',
         'original, Path(previous.__file__), Path(recipe.__file__), Path(tooling.__file__),'),
        ('One-file transfer prepared;','Three-file transfer prepared;'),
    ):
        text=recipe.once(text,old,new)
    # Require the new pending-U regression explicitly, not just the older
    # warm functional corpus which failed to reject CURRENT_U_ONLY.
    text=recipe.once(text,"    assert audit['audit_passed']",
        "    assert audit['audit_passed']\n"
        "    assert audit['authenticated_input_replay'] and not audit['candidate_fresh_qemu']\n"
        "    assert audit['pending_translation']['first_v_pairs']==72\n"
        "    assert audit['pending_translation']['cycle_delta']==0")
    ast.parse(text)
    return original,text


original,derived=derive()
exec(compile(derived,str(__file__),'exec'),globals())
