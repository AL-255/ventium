"""Build the two-header hint cofactor on the full MC-local core.

Retain the complete source closure, UV-fast defines, assertions, private C++
host and generated-header dependency audit. No acceptance is inferred.
"""
import ast
import json
from pathlib import Path

import build_mc_local_core as previous
from prepare_prime_coherence_cut import CHANGES
from run_intent_ready_pairs import replace
from run_parallel_tag_cache import sha

HERE=Path(__file__).resolve().parent
MODEL='2c54f961e87147003dd75909a361f1f9213f6453bbe6f1bce8ed512cb3fa94e4'


def admit_leaf(root):
    before=json.loads((root/'started.json').read_text())
    done=json.loads((root/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert done['source_guard_files']==8 and done['abstract_ownership_cone']
    assert not done['sequential_core'] and not done['standard_suite']
    assert not done['hardware_acceptance'] and done['gameplay_ipc'] is None
    assert [(r['name'],r['native_exit']) for r in done['rows']]==[
        ('positive',0),('lost-poison',1),('lost-external',1),('broken-owner',1)]
    assert 'PRIME-COHERENCE-OK checks=1048576 agi=1920 ref=1920 poison=2304 external=2304 stores=61440' in done['rows'][0]['coverage']
    pins=dict(before['pins'])
    assert str(HERE/'test_prime_coherence_cut.py') in pins
    for row in done['rows']:pins.update(row['artifacts'])
    for name in ('started.json','closed.json',*(Path(p).name for p in CHANGES)):
        pins[str(root/name)]=sha(root/name)
    assert set(done['derivatives'])==set(CHANGES)
    for path,digest in done['derivatives'].items():
        assert pins[str(root/Path(path).name)]==digest
    assert all(sha(p)==h for p,h in pins.items())
    return pins


def derive():
    text=previous.derive()
    for old,new in (
        (repr(previous.__doc__),repr(__doc__)),
        ('import prepare_mc_local_commit as recipe','import prepare_prime_coherence_cut as recipe'),
        ('import test_mc_local_commit as leaf_gate','import test_prime_coherence_cut as leaf_gate'),
        ('MODEL='+repr(previous.MODEL),'MODEL='+repr(MODEL)),
        ("    changes={CHANGES[0]:recipe.transform({n:(source/'rtl/core'/n).read_text() for n in recipe.PARENTS})}\n"
         "    assert changes[CHANGES[0]]==(leaf/'core_mem_chain.svh').read_text()",
         "    transformed=recipe.transform({n:(source/n).read_text() for n in recipe.PARENTS})\n"
         "    changes={p:transformed[p] for p in CHANGES}\n"
         "    assert all(changes[p]==(leaf/Path(p).name).read_text() for p in CHANGES)"),
        ("HERE/'build_fp_high_valid_core.py',", "HERE/'build_fp_high_valid_core.py',HERE/'build_mc_local_core.py',"),
        ("host=root/('tb_mc_local_commit_'", "host=root/('tb_prime_coherence_'"),
        ('MC-LOCAL-CORE-PREPARED ', 'PRIME-COHERENCE-CORE-PREPARED '),
    ):
        text=replace(text,old,new)
    ast.parse(text)
    return text


if __name__=='__main__':exec(compile(derive(),str(__file__),'exec'),globals())
