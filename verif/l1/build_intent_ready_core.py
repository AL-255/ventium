"""Prepare/build the two-file intent-only readiness cut after native cache gates.

Preparation requires the exact parent build and the full-profile sequential
cache result. Compilation retains the bounded shared guard and private harness
object/header audit. It never grants timing or processor acceptance.
"""
import ast
import hashlib
from pathlib import Path

from run_intent_ready_pairs import replace

HERE=Path(__file__).resolve().parent
BASE_SHA='8decde5e455fd686dbdc0079489bd5ccd4eb12cbc82f573d2a170884e3907448'


def derive():
    text=(HERE/'build_fp_high_valid_core.py').read_text()
    if hashlib.sha256(text.encode()).hexdigest()!=BASE_SHA:
        raise ValueError('intent-ready core build lifecycle drift')
    def change(old,new):
        nonlocal text
        text=replace(text,old,new)
    change('import prepare_fp_high_valid_cofactor as recipe','import prepare_intent_ready_cut as recipe')
    change('import run_fp_high_valid_cache as cache_gate','import run_intent_ready_cache as cache_gate')
    change("==[(False,0,0),(True,0,1)]", "==[(False,0,0)]")
    change("        'PARALLEL-CACHE-MITER checks=737677 next=414']",
           """        'PARALLEL-CACHE-MITER checks=747037 next=463']
    assert (cache/'positive/run.log').read_text().count(
        'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4')==1
    assert not checked['whole_core'] and not checked['standard_suite']
    assert not checked['hardware_acceptance']""")
    change("    changes={p:recipe.transform((source/p).read_text(),p) for p in recipe.PARENTS}",
           """    recipe.caller_contract((source/'rtl/core/core.sv').read_text(),
                           (source/'rtl/mem/ventium_l1_axi.sv').read_text())
    assert sorted(recipe.PARENTS)==['rtl/mem/ven_l1d.sv','rtl/mem/ventium_l1_axi.sv']
    changes={p:recipe.transform((source/p).read_text(),p) for p in recipe.PARENTS}""")
    change("for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),",
           "for p in (Path(__file__).resolve(),HERE/'build_fp_high_valid_core.py',\n"
           "              HERE/'run_intent_ready_pairs.py',Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),")
    change("host=root/('tb_fp_high_valid_'", "host=root/('tb_intent_ready_'")
    change('FP-HIGH-VALID-CORE-PREPARED ', 'INTENT-READY-CORE-PREPARED ')
    ast.parse(text)
    return text


if __name__=='__main__':
    exec(compile(derive(),str(__file__),'exec'),globals())
