"""Build the private two-file payload-region derivative after native micro/cache checks.

Keep the exact parent profile, complete source closure, guarded native build,
and per-model C++ harness/header audit. Compilation is not acceptance.
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
        raise ValueError('payload-region core build lifecycle drift')
    def change(old,new):
        nonlocal text
        text=replace(text,old,new)
    change('"""'+ast.get_docstring(ast.parse(text))+'"""',repr(__doc__))
    change('import prepare_fp_high_valid_cofactor as recipe','import prepare_payload_region_hint as recipe')
    change('import run_fp_high_valid_cache as cache_gate','import run_payload_region_cache as cache_gate')
    change('==[(False,0,0),(True,0,1)]','==[(False,0,0)]')
    change("        'PARALLEL-CACHE-MITER checks=737677 next=414']", """        'PARALLEL-CACHE-MITER checks=747037 next=463']
    assert (cache/'positive/run.log').read_text().count(
        'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4')==1
    assert not checked['whole_core'] and not checked['standard_suite']
    assert not checked['hardware_acceptance']""")
    change("    changes={p:recipe.transform((source/p).read_text(),p) for p in recipe.PARENTS}",
           """    assert sorted(recipe.PARENTS)==['rtl/mem/ven_l1d.sv','rtl/mem/ventium_l1_axi.sv']
    assert sha(source/'rtl/northbridge/ven_cachemap.sv')==recipe.CACHEMAP
    changes={p:recipe.transform((source/p).read_text(),p) for p in recipe.PARENTS}""")
    change('for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),',
           "for p in (Path(__file__).resolve(),HERE/'build_fp_high_valid_core.py',\n"
           "              HERE/'run_intent_ready_pairs.py',Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),")
    change("host=root/('tb_fp_high_valid_'","host=root/('tb_payload_region_'")
    change('FP-HIGH-VALID-CORE-PREPARED ','PAYLOAD-REGION-CORE-PREPARED ')
    ast.parse(text)
    return text


if __name__=='__main__': exec(compile(derive(),str(__file__),'exec'),globals())
