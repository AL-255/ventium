"""Build one private header change with the unchanged full-core build guard.

Admit the exact source-audited leaf result; retain all 195 parent sources,
152 UV-fast defines, unique C++ host and matching generated-header audit.
"""
import ast
import hashlib
import json
from pathlib import Path

from run_intent_ready_pairs import replace
from run_parallel_tag_cache import sha

HERE=Path(__file__).resolve().parent
BASE_SHA='8decde5e455fd686dbdc0079489bd5ccd4eb12cbc82f573d2a170884e3907448'
MODEL='0a6bbdb15f7ed7994641ab7ea1934a0d830b5f50d857853e5bbea29140a18e4f'
CHANGES=['rtl/core/core_mem_chain.svh']


def admit_leaf(root):
    before=json.loads((root/'started.json').read_text())
    done=json.loads((root/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert done['source_guard_files']==3 and done['source_scope_exact']
    assert done['abstract_selector_contract'] and not done['sequential_core']
    assert not done['hardware_acceptance'] and done['gameplay_ipc'] is None
    assert [(r['name'],r['native_exit']) for r in done['rows']]==[
        ('positive',0),('unguarded-agi',1),('unguarded-ref',1)]
    assert 'MC-LOCAL-OK checks=262144 chain=20480 prime=10880 other=57344 rejected=1920' in done['rows'][0]['coverage']
    pins=dict(before['pins'])
    assert str(HERE/'test_mc_local_commit.py') in pins
    for row in done['rows']:pins.update(row['artifacts'])
    for name in ('started.json','closed.json','core_mem_chain.svh'):
        pins[str(root/name)]=sha(root/name)
    assert pins[str(root/'core_mem_chain.svh')]==done['derivative_sha256']
    assert all(sha(p)==h for p,h in pins.items())
    return pins


def derive():
    text=(HERE/'build_fp_high_valid_core.py').read_text()
    if hashlib.sha256(text.encode()).hexdigest()!=BASE_SHA:
        raise ValueError('local-commit core lifecycle drift')
    def change(old,new):
        nonlocal text
        text=replace(text,old,new)
    change('"""'+ast.get_docstring(ast.parse(text))+'"""',repr(__doc__))
    change('import prepare_fp_high_valid_cofactor as recipe','import prepare_mc_local_commit as recipe')
    change('import run_fp_high_valid_cache as cache_gate','import test_mc_local_commit as leaf_gate')
    change('MODEL=cache_gate.MODEL','MODEL='+repr(MODEL))
    change('cache=args.cache.resolve(strict=True)','leaf=args.leaf.resolve(strict=True)')
    start=text.index("    checked=load(cache/'closed.json')")
    end=text.index("    source=parent/'candidate'",start)
    text=text[:start]+"    pins={**before['pins'],**admit_leaf(leaf)}\n"+text[end:]
    change('    changes={p:recipe.transform((source/p).read_text(),p) for p in recipe.PARENTS}',
           "    changes={CHANGES[0]:recipe.transform({n:(source/'rtl/core'/n).read_text() for n in recipe.PARENTS})}")
    change("    assert changes['rtl/mem/ven_l1d.sv']==(cache/'positive/ven_l1d.sv').read_text()",
           "    assert changes[CHANGES[0]]==(leaf/'core_mem_chain.svh').read_text()")
    change('Path(cache_gate.__file__).resolve()', 'Path(leaf_gate.__file__).resolve()')
    change("cache/'closed.json'", "leaf/'closed.json'")
    # The build function's source-scope equality now names the sole changed
    # header, not all three source files used to prove selector exclusion.
    assert text.count('sorted(recipe.PARENTS)')==2
    text=text.replace('sorted(recipe.PARENTS)','sorted(CHANGES)')
    change("host=root/('tb_fp_high_valid_'", "host=root/('tb_mc_local_commit_'")
    change('FP-HIGH-VALID-CORE-PREPARED ', 'MC-LOCAL-CORE-PREPARED ')
    change("for key in ('parent','cache')", "for key in ('parent','leaf')")
    change('assert args.parent and args.cache', 'assert args.parent and args.leaf')
    change('for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),',
           "for p in (Path(__file__).resolve(),HERE/'build_fp_high_valid_core.py',\n"
           "              HERE/'run_intent_ready_pairs.py',Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),")
    ast.parse(text)
    return text


if __name__=='__main__':exec(compile(derive(),str(__file__),'exec'),globals())
