"""Reuse the guarded full-size cache miter for the exact read-ACK derivative.

Refuses to build beside Vivado; 32-job guard, complete state/data comparison,
native mutation failure and source pins remain those of the qualified runner.
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
       'import prepare_read_ack_absorption as recipe')
change("MODEL='66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750'",
       "MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'")
change("for key in ('parent','fixture','proof','out'):",
       "for key in ('parent','fixture','proof','leaf','out'):")
change("assert len(proven['rows'])==11", """assert len(proven['rows'])==7
    assert proven['analysis_only'] and not proven['rtl_modified']
    leaf=args.leaf.resolve(strict=True)
    leaf_result=load(leaf/'closed.json')
    assert leaf_result['passed'] and leaf_result['pins_unchanged']
    assert all(sha(p)==h for p,h in leaf_result['pins'].items())
    assert [(r['mode'],r['native_exit']) for r in leaf_result['rows']]==[
        ('positive',0),('lost-owner',1),('lost-residency',1),('lost-cache',1),('lost-flush',1)]
    assert sha(leaf/'ven_l1d.sv')==leaf_result['derivative_sha256']""")
change("changed=recipe.transform(original,'rtl/mem/ven_l1d.sv')",
       "changed=recipe.transform(original)\n    assert changed==(leaf/'ven_l1d.sv').read_text()")
change("pins=dict(proven['pins'])", """pins=dict(proven['pins'])
    pins.update(leaf_result['pins'])
    for p in (leaf/'closed.json',leaf/'ven_l1d.sv',Path(__file__).with_name('run_fp_high_valid_cache.py')):
        pins[str(p)]=sha(p)
    for row in leaf_result['rows']:
        for name,key in (('tb.sv','sv_sha256'),('test.vvp','binary_sha256')):
            p=leaf/row['mode']/name
            assert sha(p)==row[key]
            pins[str(p)]=row[key]
        for name in ('build.log','run.log'):
            p=leaf/row['mode']/name
            pins[str(p)]=sha(p)""")
change("folder=root/('lost-next-owner' if mutant else 'positive')",
       "folder=root/('lost-read-owner' if mutant else 'positive')")
change('''sv.write_text(changed.replace('&& !(c_next_req && rd_match)',"&& 1'b1") if mutant else changed)''',
       '''ack=recipe.ack_block(changed)
            old_owner='(rd_match && !flush_all && !snoop_inv_valid'
            assert ack.count(old_owner)==1
            broken=ack.replace(old_owner,"(1'b0 && !flush_all && !snoop_inv_valid")
            sv.write_text(changed.replace(ack,broken) if mutant else changed)''')
change("'FP-HIGH-VALID:' in log", "'FP-READ-ACK:' in log")

exec(compile(text, str(original), 'exec'), globals())
