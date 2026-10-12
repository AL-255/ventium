"""Fresh U/V admission: exact whole-cache A/B, real traffic, no state injection."""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('run_fp_high_valid_cache.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '2bff0206726bef918242e5cd40645d735334514ad5ae6965f5fa4ceef3e09508'


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


change('import prepare_fp_high_valid_cofactor as recipe','import prepare_fresh_pair_capture as recipe')
change("MODEL='66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750'",
       "MODEL='3091744d8c87eef66ed5c598d43575a80e2e8de6d0790a478de96fb0b96cb9d2'")
change("for key in ('parent','fixture','proof','out'):","for key in ('parent','fixture','leaf','out'):")
change("for k in ('parent','fixture','proof')]","for k in ('parent','fixture','leaf')]")
change("    assert all(sha(p)==h for p,h in proven['pins'].items())\n    assert len(proven['rows'])==11",
       """    assert len(proven['rows'])==34 and all(r['passed'] for r in proven['rows'])
    assert sum(not r['expected_failure'] for r in proven['rows'])==26
    assert all(r['native_exit']==(1 if r['expected_failure'] else 0) for r in proven['rows'])
    for row in proven['rows']: proven['pins'].update(row['artifacts'])
    proven['pins'][str(proof/'ven_l1d.sv')]=proven['derivative_sha256']
    assert all(sha(p)==h for p,h in proven['pins'].items())""")
change("changed=recipe.transform(original,'rtl/mem/ven_l1d.sv')",
       "changed=recipe.transform(original)\n    assert changed==(proof/'ven_l1d.sv').read_text()")
change("tb=tb.replace(anchor,'  logic c_read_ack;\\n  wire c_payload_code=c_code;\\n'+anchor)",
       """tb=tb.replace(anchor,'  logic c_read_ack;\\n  wire c_payload_code=c_code;\\n  wire c_pair_intent=c_pair_req;\\n'+anchor)
    assert tb.count('    $finish;')==1 and tb.count('  initial begin\\n')==2
    at=tb.index('  initial begin\\n')
    tb=tb[:at]+'  `include "fresh_pair_capture_leaf.svh"\\n'+tb[at:]
    tb=tb.replace('    $finish;','    run_fresh_pair_capture();\\n    $finish;')""")
change("                                   'window_write_update_leaf.svh','store_window_warm_leaf.svh'))):",
       "                                   'window_write_update_leaf.svh','store_window_warm_leaf.svh',\n                                   'fresh_pair_capture_leaf.svh'))):")
change("    for row in proven['rows']:\n        for suffix,key in (('.smt2','query_sha256'),('.log','log_sha256')):\n            path=proof/(row['name']+suffix); assert sha(path)==row[key]; pins[str(path)]=row[key]\n",
       "    pins[str(Path(__file__).with_name('run_fp_high_valid_cache.py'))]=sha(Path(__file__).with_name('run_fp_high_valid_cache.py'))\n")
change("folder=root/('lost-next-owner' if mutant else 'positive')",
       "folder=root/('lost-saved-window' if mutant else 'positive')")
change('''sv.write_text(changed.replace('&& !(c_next_req && rd_match)',"&& 1'b1") if mutant else changed)''',
       '''block=recipe.NEW
            assert block.count('window_valid_q &&')==1
            broken=block.replace('window_valid_q &&',"1'b0 &&")
            sv.write_text(changed.replace(block,broken) if mutant else changed)''')
change("'FP-HIGH-VALID:' in log", "'FRESH-PAIR-CAPTURE:' in log or 'FRESH-PAIR-' in log")
change("'STORE-WARM-OK','RESPONSE-PAYLOAD-OK','HIGH-WINDOW-PAYLOAD-OK'):",
       "'STORE-WARM-OK','RESPONSE-PAYLOAD-OK','HIGH-WINDOW-PAYLOAD-OK',\n                               'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4'):")
change("            print(json.dumps({k:v for k,v in row.items() if k not in ('command','artifacts')}),flush=True)",
       """            row['compiler_archive']=miter.archive_products(folder,'tb_l1d_mem_chain')
            print(json.dumps({k:v for k,v in row.items() if k not in ('command','artifacts','compiler_archive')}),flush=True)""")

exec(compile(text, str(original), 'exec'), globals())
