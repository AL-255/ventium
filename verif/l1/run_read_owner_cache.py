"""Run the full-P5 state/data miter on the exact read-owner ACK derivative."""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('run_fp_high_valid_cache.py')
text = original.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == '2bff0206726bef918242e5cd40645d735334514ad5ae6965f5fa4ceef3e09508'


def change(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


change('import prepare_fp_high_valid_cofactor as recipe',
       'import prepare_read_owner_ack as recipe')
change("MODEL='66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750'",
       "MODEL='f3fb3256fb40d9af50d73f2ac80b26bb4f5e27ff4b95d9f279172b4e0c025e41'")
change("for key in ('parent','fixture','proof','out'):",
       "for key in ('parent','fixture','leaf','out'):")
change("for k in ('parent','fixture','proof')]", "for k in ('parent','fixture','leaf')]")
change("    assert all(sha(p)==h for p,h in proven['pins'].items())\n    assert len(proven['rows'])==11",
       """    proven['pins']=load(proof/'started.json')['pins']
    proven['pins'][str(proof/'started.json')]=sha(proof/'started.json')
    assert [(r['mode'],r['native_exit']) for r in proven['rows']]==[
        ('positive-base',0),('positive-datafill',0),('positive-no-fill',0),
        ('lost-owner',1),('lost-residency',1),('lost-cache',1),('lost-flush',1),
        ('lost-code-fill-exclusion',1)]
    for row in proven['rows']: proven['pins'].update(row['artifacts'])
    assert all(sha(p)==h for p,h in proven['pins'].items())
    assert sha(proof/'ven_l1d.sv')==proven['derivative_sha256']
    proven['pins'][str(proof/'ven_l1d.sv')]=proven['derivative_sha256']""")
change("changed=recipe.transform(original,'rtl/mem/ven_l1d.sv')",
       "changed=recipe.transform(original)\n    assert changed==(proof/'ven_l1d.sv').read_text()")
change("tb=tb.replace(anchor,'  logic c_read_ack;\\n  wire c_payload_code=c_code;\\n'+anchor)",
       "tb=tb.replace(anchor,'  logic c_read_ack;\\n  wire c_payload_code=c_code;\\n  wire c_pair_intent=c_pair_req;\\n'+anchor)")
change("    for row in proven['rows']:\n        for suffix,key in (('.smt2','query_sha256'),('.log','log_sha256')):\n            path=proof/(row['name']+suffix); assert sha(path)==row[key]; pins[str(path)]=row[key]\n",
       "    pins[str(Path(__file__).with_name('run_fp_high_valid_cache.py'))]=sha(Path(__file__).with_name('run_fp_high_valid_cache.py'))\n")
change("folder=root/('lost-next-owner' if mutant else 'positive')",
       "folder=root/('lost-read-owner' if mutant else 'positive')")
change('''sv.write_text(changed.replace('&& !(c_next_req && rd_match)',"&& 1'b1") if mutant else changed)''',
       '''ack=recipe.ack_block(changed)
            before='(rd_match && !flush_all && !snoop_inv_valid'
            broken=recipe.replace(ack,before,"(1'b0 && !flush_all && !snoop_inv_valid")
            sv.write_text(changed.replace(ack,broken) if mutant else changed)''')
change("'FP-HIGH-VALID:' in log", "'FP-READ-ACK:' in log or 'READ-OWNER-ACK:' in log")
change("            print(json.dumps({k:v for k,v in row.items() if k not in ('command','artifacts')}),flush=True)",
       """            row['compiler_archive']=miter.archive_products(folder,'tb_l1d_mem_chain')
            print(json.dumps({k:v for k,v in row.items() if k not in ('command','artifacts','compiler_archive')}),flush=True)""")

exec(compile(text, str(original), 'exec'), globals())
