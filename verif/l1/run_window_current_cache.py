"""Full-P5 cache A/B for the private saved-window cofactor.

Preserve the existing guarded fixture, all ordinary outputs and both-edge
bank/tag/owner comparisons. No new core model, synthesis or hardware acceptance.
"""
import ast
import json
from pathlib import Path

import run_payload_region_cache as previous
from run_intent_ready_pairs import replace
from run_parallel_tag_cache import sha

HERE = Path(__file__).resolve().parent
MODEL = '0a6bbdb15f7ed7994641ab7ea1934a0d830b5f50d857853e5bbea29140a18e4f'


def admit_proof(root):
    done = json.loads((root/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged']
    assert done['abstract_combinational_contract'] and not done['automatic_rtl_formal']
    assert not done['sequential_cache'] and not done['whole_core']
    assert not done['hardware_acceptance'] and done['gameplay_ipc'] is None
    expected = [(n, 'unsat') for n in ('primary-equivalence', 'shadow-equivalence',
                'current-excludes-prime', 'reuse-selects-current')]
    expected += [(n, 'sat') for n in ('lost-next-owner', 'wrong-tags',
                                     'lost-residency', 'lost-primary-owner')]
    assert [(r['name'], r['answer']) for r in done['rows']] == expected
    pins = dict(done['pins'])
    assert str(HERE/'prove_window_current_reuse.py') in pins
    for row in done['rows']:
        assert row['native_exit'] == 0
        for suffix, key in (('.smt2', 'query_sha256'), ('.log', 'log_sha256')):
            path = root/(row['name']+suffix)
            assert path.read_text().strip() == row['answer'] if suffix == '.log' else True
            pins[str(path)] = row[key]
    pins[str(root/'closed.json')] = sha(root/'closed.json')
    assert all(sha(p) == h for p, h in pins.items())
    return pins


def mutate(changed, original, recipe):
    """Remove next ownership only from the new primary equation, not witnesses."""
    old = recipe.replacement(recipe.equation(original, 'window_reuse'))
    assert changed.count(old) == 1 and old.count('!(c_next_req && rd_match)') == 2
    return changed.replace(old, old.replace('!(c_next_req && rd_match)', "1'b1"))


def derive():
    text = previous.derive()
    def change(old, new):
        nonlocal text
        text = replace(text, old, new)
    change(repr(previous.__doc__), repr(__doc__))
    change('import prepare_payload_region_hint as recipe',
           'import prepare_window_current_reuse as recipe')
    change('MODEL='+repr(previous.MODEL), 'MODEL='+repr(MODEL))
    change('proven=dict(pins=admit_leaf(proof))', 'proven=dict(pins=admit_proof(proof))')
    change("changed=recipe.transform(original,'rtl/mem/ven_l1d.sv')",
           'changed=recipe.transform(original)')
    change('  logic c_read_ack, c_pair_intent_ready;',
           '  logic c_read_ack, c_pair_intent_ready, c_rdata_hi_uncontended;')
    change('miter.BASE_OUTPUTS.update(c_read_ack=1,c_pair_ready=1,c_pair_intent_ready=1,c_pair_ack=1,',
           'miter.BASE_OUTPUTS.update(c_read_ack=1,c_pair_ready=1,c_pair_intent_ready=1,c_pair_ack=1,\n'
           '        c_rdata_hi_uncontended=1,')
    change("    for path in (HERE/'run_fp_high_valid_cache.py',HERE/'run_intent_ready_pairs.py'):",
           "    for path in (HERE/'run_fp_high_valid_cache.py',HERE/'run_intent_ready_pairs.py',\n"
           "                 HERE/'run_payload_region_cache.py'):")
    change('        for mutant in (False,):', '        for mutant in (False,True):')
    change("folder=root/'positive'", "folder=root/('lost-next-owner' if mutant else 'positive')")
    change('            sv.write_text(changed)',
           '            sv.write_text(mutate(changed,original,recipe) if mutant else changed)')
    change("'FP-HIGH-VALID:' in log or 'PARALLEL-CACHE-MISMATCH' in log",
           "'WINDOW-CURRENT-REUSE:' in log or 'PARALLEL-CACHE-MISMATCH' in log")
    # Directly observe both changed expressions as well as their sequential
    # consequences; retain all original both-edge output/bank comparisons.
    change('''      $fatal(1,"PAYLOAD-REGION-FULL: saved shadow line differs");
`endif
    parallel_cache_checks++;''', '''      $fatal(1,"PAYLOAD-REGION-FULL: saved shadow line differs");
`endif
    if (dut.window_reuse !== control.window_reuse ||
        dut.shadow_reuse !== control.shadow_reuse)
      $fatal(1,"PARALLEL-CACHE-MISMATCH saved-window cofactor");
    parallel_cache_checks++;''')
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
