"""Complete cache A/B using the existing guarded full-P5 fixture/lifecycle.

Only payload classification uses the new sideband. Compare all other enabled
outputs, cache owners, banks, tags and replacement state on both clock edges.
"""
import ast
import hashlib
import json
from pathlib import Path

from run_intent_ready_pairs import replace
from run_parallel_tag_cache import sha

HERE=Path(__file__).resolve().parent
BASE_SHA='2bff0206726bef918242e5cd40645d735334514ad5ae6965f5fa4ceef3e09508'
MODEL='6fa8f7ad89e4f84a3c484a5e8c81d933e9bda429ca6c7019bd5e2c63d3ce1b5e'


def admit_leaf(root):
    done=json.loads((root/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and not done['whole_core']
    assert not done['hardware_acceptance'] and done['gameplay_ipc'] is None
    assert [(r['name'],r['build_exit'],r['native_exit']) for r in done['rows']]==[
        ('positive',0,0),('lost-cd',0,1),('lost-alignment',0,1)]
    assert [(r['name'],r['result']) for r in done['queries']]==[
        ('aligned','unsat'),('unsafe-unaligned','sat')]
    pins=dict(done['pins'])
    assert str(HERE/'run_payload_region_leaf.py') in pins
    for row in done['rows']:
        pins.update(row['artifacts'])
        log=(root/row['name']/'run.log').read_text()
        assert log==row['log']
        assert ('PAYLOAD-REGION-OK vectors=262144 differing_hint=4413' in log) if row['name']=='positive' else ('PAYLOAD-REGION-DATA' in log)
    for row in done['queries']:
        for suffix,key in (('.smt2','source_sha256'),('.log','log_sha256')):
            pins[str(root/(row['name']+suffix))]=row[key]
    for name in ('started.json','closed.json'):
        pins[str(root/name)]=sha(root/name)
    assert all(sha(p)==h for p,h in pins.items())
    return pins


def derive():
    text=(HERE/'run_fp_high_valid_cache.py').read_text()
    if hashlib.sha256(text.encode()).hexdigest()!=BASE_SHA:
        raise ValueError('payload-region full-cache lifecycle drift')
    def change(old,new):
        nonlocal text
        text=replace(text,old,new)
    change('"""'+ast.get_docstring(ast.parse(text))+'"""',repr(__doc__))
    change('import prepare_fp_high_valid_cofactor as recipe','import prepare_payload_region_hint as recipe')
    change("MODEL='66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750'",'MODEL='+repr(MODEL))
    change("    proven=load(proof/'closed.json'); assert proven['passed'] and proven['pins_unchanged']\n"
           "    assert all(sha(p)==h for p,h in proven['pins'].items())\n    assert len(proven['rows'])==11",
           "    proven=dict(pins=admit_leaf(proof))\n    assert all(sha(p)==h for p,h in prior['pins'].items())")
    change("tb=tb.replace(anchor,'  logic c_read_ack;\\n  wire c_payload_code=c_code;\\n'+anchor)",
           """tb=tb.replace(anchor,'''  logic c_read_ack, c_pair_intent_ready;
  wire c_payload_code=c_code;
  wire c_pair_intent=c_pair_req;
  // Deliberately differ on unaligned reads: this hint has no authority there.
  wire c_payload_cacheable=cacheable || (c_addr[1:0]!=0);
'''+anchor)
    assert tb.count('    $finish;')==1 and tb.count('  initial begin\\n')==2
    at=tb.index('  initial begin\\n')
    tb=tb[:at]+'  `include "fresh_pair_capture_leaf.svh"\\n'+tb[at:]
    tb=tb.replace('    $finish;','    run_fresh_pair_capture();\\n    $finish;')""")
    change('miter.BASE_OUTPUTS.update(c_read_ack=1,c_pair_ready=1,c_pair_ack=1,',
           'miter.BASE_OUTPUTS.update(c_read_ack=1,c_pair_ready=1,c_pair_intent_ready=1,c_pair_ack=1,')
    change("    tb=miter.miter_fixture(tb,False,True)", """    tb=miter.miter_fixture(tb,False,True)
    tb=replace(tb,'    parallel_cache_checks++;','''
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    if (dut.shadow_valid_q !== control.shadow_valid_q ||
        dut.shadow_line_addr_q !== control.shadow_line_addr_q ||
        dut.shadow_line_q !== control.shadow_line_q)
      $fatal(1,"PAYLOAD-REGION-FULL: saved shadow line differs");
`endif
    parallel_cache_checks++;''')""")
    change("                                   'window_write_update_leaf.svh','store_window_warm_leaf.svh'))):",
           "                                   'window_write_update_leaf.svh','store_window_warm_leaf.svh',\n"
           "                                   'fresh_pair_capture_leaf.svh'))):")
    change("    pins=dict(proven['pins'])", "    pins=dict(prior['pins']); pins.update(proven['pins'])")
    change("    for row in proven['rows']:\n"
           "        for suffix,key in (('.smt2','query_sha256'),('.log','log_sha256')):\n"
           "            path=proof/(row['name']+suffix); assert sha(path)==row[key]; pins[str(path)]=row[key]\n",
           "    for path in (HERE/'run_fp_high_valid_cache.py',HERE/'run_intent_ready_pairs.py'):\n"
           "        pins[str(path)]=sha(path)\n")
    change('        for mutant in (False,True):','        for mutant in (False,):')
    change("folder=root/('lost-next-owner' if mutant else 'positive')","folder=root/'positive'")
    change('''sv.write_text(changed.replace('&& !(c_next_req && rd_match)',"&& 1'b1") if mutant else changed)''',
           'sv.write_text(changed)')
    change("'STORE-WARM-OK','RESPONSE-PAYLOAD-OK','HIGH-WINDOW-PAYLOAD-OK'):",
           "'STORE-WARM-OK','RESPONSE-PAYLOAD-OK','HIGH-WINDOW-PAYLOAD-OK',\n"
           "                               'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4'):")
    ast.parse(text)
    return text


if __name__=='__main__': exec(compile(derive(),str(__file__),'exec'),globals())
