"""Full-P5 sequential A/B for V-only capture/return exclusion.

Adds real saved-window and two-lane priority traffic to the unchanged cache
corpus. No hierarchical state writes, core-mode change or hardware acceptance.
"""
import ast
import json
from pathlib import Path

import run_window_current_cache as previous
from run_intent_ready_pairs import replace
from run_parallel_tag_cache import sha

HERE=Path(__file__).resolve().parent


def admit_proof(root):
    done=json.loads((root/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and done['abstract_combinational_contract']
    assert not done['automatic_rtl_formal'] and not done['sequential_cache'] and not done['whole_core']
    assert not done['hardware_acceptance'] and done['gameplay_ipc'] is None
    expected=[(n,'unsat') for n in ('v-only-exclusion','hit-equivalence',
                                  'saved-excludes-fresh','request-excludes-prime')]
    expected += [(n,'sat') for n in ('lost-two-lane-priority','lost-legacy-v-only-guard',
                                  'lost-fresh-saved-guard','lost-prime-request-guard','lost-store-write-guard')]
    assert [(r['name'],r['answer']) for r in done['rows']]==expected
    pins=dict(done['pins']);assert str(HERE/'prove_pair_now_capture.py') in pins
    for row in done['rows']:
        assert row['native_exit']==0
        for suffix,key in (('.smt2','query_sha256'),('.log','log_sha256')):
            pins[str(root/(row['name']+suffix))]=row[key]
    pins[str(root/'closed.json')]=sha(root/'closed.json')
    assert all(sha(p)==h for p,h in pins.items())
    return pins


def mutate(changed,original,recipe):
    # Leave the original reference witness intact. Native traffic must catch
    # this unsafe generalization even though V-only cases remain equivalent.
    assert changed.count(recipe.NEW)==1 and recipe.NEW.count('pair_req_valid[0] &&')==1
    return changed.replace(recipe.NEW,recipe.NEW.replace('pair_req_valid[0] &&',"1'b0 &&"))


def derive():
    text=previous.derive()
    def change(old,new):
        nonlocal text
        text=replace(text,old,new)
    change(repr(previous.__doc__),repr(__doc__))
    change('import prepare_window_current_reuse as recipe','import prepare_pair_now_capture as recipe')
    change("folder=root/('lost-next-owner' if mutant else 'positive')",
           "folder=root/('lost-two-lane-priority' if mutant else 'positive')")
    change("'WINDOW-CURRENT-REUSE:' in log","'PAIR-NOW-CAPTURE:' in log")
    change('''    if (dut.window_reuse !== control.window_reuse ||
        dut.shadow_reuse !== control.shadow_reuse)
      $fatal(1,"PARALLEL-CACHE-MISMATCH saved-window cofactor");''',
           '''    if (dut.pair_hit !== control.pair_hit)
      $fatal(1,"PARALLEL-CACHE-MISMATCH pair capture hit");''')
    change('    tb=miter.miter_fixture(tb,False,True)', '''    tb=replace(tb,'  `include "fresh_pair_capture_leaf.svh"',
        '  `include "fresh_pair_capture_leaf.svh"\\n  `include "pair_now_capture_leaf.svh"')
    tb=replace(tb,'    run_fresh_pair_capture();\\n    $finish;',
        '    run_fresh_pair_capture();\\n    run_pair_now_capture();\\n    $finish;')
    tb=miter.miter_fixture(tb,False,True)''')
    change("                 HERE/'run_payload_region_cache.py'):",
           "                 HERE/'run_payload_region_cache.py',HERE/'run_window_current_cache.py'):")
    change("                                   'fresh_pair_capture_leaf.svh'))):",
           "                                   'fresh_pair_capture_leaf.svh','pair_now_capture_leaf.svh'))):")
    change("'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4'):",
           "'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4',\n"
           "                               'PAIR-NOW-FULL-OK cases=128 immediate=106 denied=22 standalone=2 fresh=2'):")
    ast.parse(text)
    return text


if __name__=='__main__':exec(compile(derive(),str(__file__),'exec'),globals())
