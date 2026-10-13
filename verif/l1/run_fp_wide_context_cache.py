"""Whole-cache contextual-valid A/B, preserving all ordinary grants and state.

Use the frozen PAYLOAD-REGION model/152-define profile and existing full-size
traffic fixture. A second native build deliberately replaces the general grant
with the contextual expression: this misuse must fail. No core/FPGA acceptance.
"""
import ast
import json
from pathlib import Path

import run_payload_region_cache as previous
import prove_fp_wide_context as proof_gate
from run_intent_ready_pairs import replace
from run_parallel_tag_cache import sha

HERE = Path(__file__).resolve().parent
MODEL = '3a91aa88841f949855d27e0ed500064854ad9b24390c318629054de858061164'


def admit_proof(root):
    done = json.loads((root/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and not done['whole_core']
    assert done['abstract_combinational_contract'] and done['source_guard_mutants'] == 6
    assert not done['hardware_acceptance'] and done['gameplay_ipc'] is None
    expected = [('fload-excludes-next', 'unsat'), ('fload-wide-equivalence', 'unsat'),
                ('fload-seam-equivalence', 'unsat'), ('take-equivalence', 'unsat'),
                ('command-equivalence', 'unsat'), ('not-a-general-grant', 'sat')]
    expected += [('unguarded-'+offer, 'sat') for offer in ('agi', 'ref', 'offer', 'prime')]
    assert [(r['name'], r['answer']) for r in done['rows']] == expected
    pins = dict(done['pins'])
    assert str(Path(proof_gate.__file__).resolve()) in pins
    for row in done['rows']:
        assert row['native_exit'] == 0
        pins.update(row['artifacts'])
    pins[str(root/'closed.json')] = sha(root/'closed.json')
    assert all(sha(p) == h for p, h in pins.items())
    return pins


def derive():
    text = previous.derive()
    def change(old, new):
        nonlocal text
        text = replace(text, old, new)
    change(repr(previous.__doc__), repr(__doc__))
    change('import prepare_payload_region_hint as recipe', 'import prepare_fp_wide_context as recipe')
    change('MODEL='+repr(previous.MODEL), 'MODEL='+repr(MODEL))
    change('proven=dict(pins=admit_leaf(proof))', 'proven=dict(pins=admit_proof(proof))')
    change('  logic c_read_ack, c_pair_intent_ready;',
           '  logic c_read_ack, c_pair_intent_ready, c_rdata_hi_uncontended;')
    change("    tb=miter.miter_fixture(tb,False,True)", '''    tb=miter.miter_fixture(tb,False,True)
    tb=replace(tb,'  integer parallel_cache_checks=0, parallel_cache_next_checks=0;',
        '  integer parallel_cache_checks=0, parallel_cache_next_checks=0;\\n'
        '  integer fp_context_checks=0, fp_context_high=0, fp_context_different=0;')
    tb=replace(tb,'    parallel_cache_checks++;',\'''    if (rst_n && !c_next_req) begin
      if (dut.c_rdata_hi_uncontended !== control.c_rdata_hi_valid)
        $fatal(1,"FP-WIDE-CACHE: uncontended output differs");
      if (dut.c_rdata_hi_uncontended && (!dut.c_read_ack || !c_req || c_we))
        $fatal(1,"FP-WIDE-CACHE: missing read owner");
      fp_context_checks++;
      if (dut.c_rdata_hi_uncontended) fp_context_high++;
    end
    if (rst_n && dut.c_rdata_hi_uncontended !== control.c_rdata_hi_valid)
      fp_context_different++;
    parallel_cache_checks++;\''')
    tb=replace(tb,'    run_fresh_pair_capture();\\n    $finish;',\'''    run_fresh_pair_capture();
    if (!fp_context_checks || !fp_context_high || !fp_context_different)
      $fatal(1,"FP-WIDE-CACHE: missing context coverage");
    $display("FP-WIDE-CACHE-OK checks=%0d high=%0d different=%0d",
             fp_context_checks,fp_context_high,fp_context_different);
    $finish;\''')''')
    change("    for path in (HERE/'run_fp_high_valid_cache.py',HERE/'run_intent_ready_pairs.py'):",
           "    for path in (HERE/'run_fp_high_valid_cache.py',HERE/'run_intent_ready_pairs.py',\n"
           "                 HERE/'run_payload_region_cache.py',HERE/'prove_fp_wide_context.py'):")
    change('        for mutant in (False,):', '        for mutant in (False,True):')
    change("folder=root/'positive'", "folder=root/('general-grant-misuse' if mutant else 'positive')")
    change('            sv.write_text(changed)',
           "            assert changed.count(recipe.ARBITRATION)==1\n"
           "            sv.write_text(changed.replace(recipe.ARBITRATION,'') if mutant else changed)")
    change("'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4'):",
           "'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4',\n"
           "                               'FP-WIDE-CACHE-OK'):")
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
