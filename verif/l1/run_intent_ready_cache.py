"""Full-profile cache A/B for the private intent-qualified readiness cut.

Requires the native paired-store matrix first; inherits the guarded full-cache
lifecycle, all original public traffic and 51 fresh-capture corner cases. This
is not whole-core, timing, standard-suite or FPGA acceptance.
"""
import ast
import hashlib
from pathlib import Path

import run_intent_ready_pairs as paired

HERE=Path(__file__).resolve().parent
BASE_SHA='2bff0206726bef918242e5cd40645d735334514ad5ae6965f5fa4ceef3e09508'
MODEL='e1621913f28c5cd1c10b0c19f57bc59277807034dfb6b94a79bd7fe58d6a1a81'


def admit_pairs(root):
    import json
    from run_parallel_tag_cache import sha
    done=json.loads((root/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and not done['hardware_acceptance']
    expected=[f'positive-lut{f}-windows{w}' for f in (0,1) for w in range(3)]
    expected+=['wrong-lookup-lut1-windows2','wrong-credit-lut1-windows2']
    assert [r['label'] for r in done['rows']]==expected
    pins=dict(done['pins'])
    assert str(HERE/'run_intent_ready_pairs.py') in pins
    for row in done['rows']:
        assert row['build_exit']==0
        assert (row['native_exit']!=0) if row['mutant'] else (row['native_exit']==0)
        folder=root/row['label']
        for suffix,key in (('obj/Vtb_l1d_pair_store','binary_sha256'),
                           ('build.log','build_log_sha256'),('run.log','log_sha256')):
            pins[str(folder/suffix)]=row[key]
    pins.update({str(root/n):sha(root/n) for n in ('started.json','closed.json')})
    assert all(sha(p)==h for p,h in pins.items())
    return pins


def derive():
    text=(HERE/'run_fp_high_valid_cache.py').read_text()
    if hashlib.sha256(text.encode()).hexdigest()!=BASE_SHA:
        raise ValueError('intent-ready full-cache lifecycle drift')
    def change(old,new):
        nonlocal text
        text=paired.replace(text,old,new)
    change('import prepare_fp_high_valid_cofactor as recipe','import prepare_intent_ready_cut as recipe')
    change("MODEL='66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750'",
           'MODEL='+repr(MODEL))
    change("    args=ap.parse_args()", "    ap.add_argument('--pairs',type=Path,required=True)\n    args=ap.parse_args()")
    change("    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0",
           "    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0\n"
           "    assert all(sha(p)==h for p,h in prior['pins'].items())")
    change("    proven=load(proof/'closed.json'); assert proven['passed'] and proven['pins_unchanged']\n"
           "    assert all(sha(p)==h for p,h in proven['pins'].items())\n    assert len(proven['rows'])==11",
           "    proven=dict(pins=paired.admit_proof(proof))\n"
           "    proven['pins'].update(admit_pairs(args.pairs.resolve(strict=True)))")
    change("    original=source.read_text(); changed=recipe.transform(original,'rtl/mem/ven_l1d.sv')",
           """    core=parent/'candidate/rtl/core/core.sv'; seam=source.with_name('ventium_l1_axi.sv')
    recipe.caller_contract(core.read_text(),seam.read_text())
    original=source.read_text(); changed=recipe.transform(original,'rtl/mem/ven_l1d.sv')
    assert changed==(args.pairs.resolve(strict=True)/'ven_l1d.sv').read_text()""")
    change("tb=tb.replace(anchor,'  logic c_read_ack;\\n  wire c_payload_code=c_code;\\n'+anchor)",
           """tb=tb.replace(anchor,'  logic c_read_ack, c_pair_intent_ready;\\n  wire c_payload_code=c_code;\\n  wire c_pair_intent=c_pair_req;\\n'+anchor)
    assert tb.count('    $finish;')==1 and tb.count('  initial begin\\n')==2
    at=tb.index('  initial begin\\n')
    tb=tb[:at]+'  `include "fresh_pair_capture_leaf.svh"\\n'+tb[at:]
    tb=tb.replace('    $finish;','    run_fresh_pair_capture();\\n    $finish;')""")
    change("    tb=miter.miter_fixture(tb,False,True)", """    tb=miter.miter_fixture(tb,False,True)
    tb=paired.replace(tb,'    parallel_cache_checks++;','''    if (rst_n && c_pair_intent &&
        c_pair_intent_ready !== shadow_c_pair_ready)
      $fatal(1,"INTENT-READY-FULL: qualified readiness differs");
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    if (dut.shadow_valid_q !== control.shadow_valid_q ||
        dut.shadow_line_addr_q !== control.shadow_line_addr_q ||
        dut.shadow_line_q !== control.shadow_line_q)
      $fatal(1,"INTENT-READY-FULL: saved shadow line differs");
`endif
    parallel_cache_checks++;''')""")
    change("                                   'window_write_update_leaf.svh','store_window_warm_leaf.svh'))):",
           "                                   'window_write_update_leaf.svh','store_window_warm_leaf.svh',\n"
           "                                   'fresh_pair_capture_leaf.svh'))):")
    change("    pins=dict(proven['pins'])", "    pins=dict(prior['pins']); pins.update(proven['pins'])")
    change("    for row in proven['rows']:\n"
           "        for suffix,key in (('.smt2','query_sha256'),('.log','log_sha256')):\n"
           "            path=proof/(row['name']+suffix); assert sha(path)==row[key]; pins[str(path)]=row[key]\n",
           """    for path in (core,seam,Path(paired.__file__),here/'run_fp_high_valid_cache.py',
                 REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh'):
        pins[str(path)]=sha(path)
""")
    # Negative controls already execute in the required paired-store matrix.
    # Do not count an unrelated, unexercised mutant as this full-profile proof.
    change('        for mutant in (False,True):','        for mutant in (False,):\n            assert shutil.disk_usage(root).free>4*1024**3')
    change("folder=root/('lost-next-owner' if mutant else 'positive')", "folder=root/'positive'")
    change('''sv.write_text(changed.replace('&& !(c_next_req && rd_match)',"&& 1'b1") if mutant else changed)''',
           'sv.write_text(changed)')
    change("'STORE-WARM-OK','RESPONSE-PAYLOAD-OK','HIGH-WINDOW-PAYLOAD-OK'):",
           "'STORE-WARM-OK','RESPONSE-PAYLOAD-OK','HIGH-WINDOW-PAYLOAD-OK',\n"
           "                               'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4'):")
    change("            print(json.dumps({k:v for k,v in row.items() if k not in ('command','artifacts')}),flush=True)",
           """            row['compiler_archive']=miter.archive_products(folder,'tb_l1d_mem_chain')
            print(json.dumps({k:v for k,v in row.items() if k not in ('command','artifacts','compiler_archive')}),flush=True)""")
    ast.parse(text)
    return text


if __name__=='__main__':
    exec(compile(derive(),str(__file__),'exec'),globals())
