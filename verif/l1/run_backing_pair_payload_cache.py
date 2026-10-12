"""Full-size sequential L1 miter for the early backing payload derivative.

Address/strobes are compared on transactions AND observable blocked-pair hints.
All other output, tag, data and state comparisons retain the qualified runner.
The flat backing model is not a substitute for real AXI credit qualification.
"""
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
       'import prepare_backing_pair_payload as recipe')
change("MODEL='66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750'",
       "MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'")
change("assert len(proven['rows'])==11", """assert len(proven['rows'])==7
    assert [(r['profile'],r['mode'],r['native_exit']) for r in proven['rows']]==[
        ('default','positive',0),('dual','positive',0),('full','positive',0),
        ('full','wrong-v',1),('full','fill-strobe',1),('full','lost-credit',1),('full','late-hint',1)]
    assert sha(proof/'ven_l1d.sv')==proven['derivative_sha256']""")
change("changed=recipe.transform(original,'rtl/mem/ven_l1d.sv')",
       "changed=recipe.transform(original)\n    assert changed==(proof/'ven_l1d.sv').read_text()")
change('    tb=miter.miter_fixture(tb,False,True)', '''    tb=miter.miter_fixture(tb,False,True)
    for name in ('m_addr','m_wstrb'):
        before=f'if (dut.{name} !== shadow_{name})'
        assert tb.count(before)==1
        tb=tb.replace(before,f'if ((dut.m_req || (dut.st==dut.L1_IDLE && c_req && !dut.stream_path)) && dut.{name} !== shadow_{name})')''')
change("pins=dict(proven['pins'])", """pins=dict(proven['pins'])
    for p in (proof/'ven_l1d.sv',Path(__file__).with_name('run_fp_high_valid_cache.py')):
        pins[str(p)]=sha(p)""")
change("""    for row in proven['rows']:
        for suffix,key in (('.smt2','query_sha256'),('.log','log_sha256')):
            path=proof/(row['name']+suffix); assert sha(path)==row[key]; pins[str(path)]=row[key]""",
       """    for row in proven['rows']:
        case=proof/(row['profile']+'-'+row['mode'])
        for name,key in (('tb.sv','sv_sha256'),('test.vvp','binary_sha256')):
            path=case/name; assert sha(path)==row[key]; pins[str(path)]=row[key]
        for name in ('build.log','run.log'):
            path=case/name; pins[str(path)]=sha(path)""")
change("folder=root/('lost-next-owner' if mutant else 'positive')",
       "folder=root/('wrong-v-address' if mutant else 'positive')")
change('''sv.write_text(changed.replace('&& !(c_next_req && rd_match)',"&& 1'b1") if mutant else changed)''',
       '''actual=recipe.block(changed)
            select="m_we=1'b1; m_addr=c_pair_addr;"
            assert actual.count(select)==1 # retained witness uses renamed outputs
            wrong=actual.replace(select,"m_we=1'b1; m_addr=c_addr;",1)
            sv.write_text(changed.replace(actual,wrong) if mutant else changed)''')
change("'FP-HIGH-VALID:' in log", "'BACKING-PAIR-PAYLOAD:' in log")

exec(compile(text, str(original), 'exec'), globals())
