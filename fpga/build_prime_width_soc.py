"""Transfer only the tested prime-width delta onto the faster full-PC parent.

Experimental build, not gate promotion: preserve both failed gate verdicts,
157 definitions, all 102 shared CPU sources and posted-16 transport.
"""
import inspect
from pathlib import Path
import sys

import build_sfetch_interior_soc as template
import build_v_result_carry_soc as original

REPO,ROOT=template.REPO,template.ROOT
sys.path.insert(0,str(REPO/'verif/l1'))
import build_prime_width_core as leaf
import prepare_prime_width_payload as recipe
from run_prime_width_func import MODEL as CORE_MODEL

base=original.base
sha,load,save,stable=base.sha,base.load,base.save,base.stable
PARENT_MODEL=template.PARENT_MODEL
CHANGES=[recipe.FILE]
check_definitions=original.check_definitions


def check_delta(name,before,after):
    if name==recipe.FILE:
        assert recipe.transform(before.decode()).encode()==after
        return True
    assert before==after,'unreviewed source change: '+name
    return False


def check_equivalence(audit):
    assert audit['same_input_equivalence'] and audit['model']==CORE_MODEL
    assert audit['parent']==leaf.MODEL
    assert not any(audit[k] for k in ('legacy_aggregate_gate_passed','canonical_gate_passed',
                                     'standard_suite','hardware_acceptance'))
    assert audit['totals']==dict(stream_pairs=4240,func_records=641832,probe_pairs=4240,
                                cycle_records=641832,actual_v_retirements=163956)
    assert audit['actual_parent_and_candidate_coverage']==dict(clocks=16951320,agi=18172,
        ref=22872,retained=0,prime=132736,intent=5616,request=3072,accept=1872,shape_only=1536)
    assert set(audit['changed_legacy_fields'])=={'clocks','ref','prime'}
    assert all(r['parent']==r['candidate'] for r in audit['changed_legacy_fields'].values())


def evidence(proof,core):
    assert proof==ROOT and core==ROOT/'prime-width-core-r1'
    pins=leaf.check_leaf(proof/'prime-width-leaf-r1')
    folder=proof/'prime-width-core-checks-r1'
    checked=load(folder/'parent-equivalence-audit.json'); check_equivalence(checked)
    pins.update(checked['pins'])
    start,done=load(folder/'started.json'),load(folder/'closed.json')
    assert not done['passed'] and done['pins_unchanged'] and len(done['errors'])==1
    assert len(done['rows'])==8 and all(row['native_exit']==0 for row in done['rows'])
    assert done['probe_runs']==4240 and done['coverage']==checked['actual_parent_and_candidate_coverage']
    assert start['pins'][str(core/'obj/tb_ventium')]==CORE_MODEL
    func=proof/'prime-width-func-r2'; audit=load(func/'audit.json')
    assert audit['passed'] and audit['model']==CORE_MODEL and not audit['canonical_gate_passed']
    assert (audit['functional_passes'],audit['functional_records'],audit['v_retirements'])==(108,80800,30132)
    assert audit['unmasked_functional_passes']==105
    assert audit['unmasked_failures']==['tx_regform','tx_regform2','tx_stack']
    pins.update(audit['pins']);pins.update(audit['artifacts'])
    gate=load(core/'verify-closed.json')
    assert gate['canonical_gate_native_exit']==2 and not gate['canonical_gate_passed']
    assert gate['pins_unchanged'] and not gate['masks_or_goldens_or_bands_changed']
    assert len(gate['deltas'])==20 and all(r['same_records'] for r in gate['deltas'])
    pins.update(load(core/'verify-started.json')['pins'])
    for p in (folder/'parent-equivalence-audit.json',func/'audit.json',core/'verify-started.json',
              core/'verify-closed.json',Path(template.__file__),Path(original.__file__)):
        pins[str(p.resolve())]=sha(p)
    assert stable(pins)
    return pins


def prepare_source():
    assert sha(template.__file__)=='ff4319fbf6b7682693ce17d23bc82ff3f974b302aedb46519852a2c31d432779'
    text=template.prepare_source()
    for old,new in (
        ("'sim_sfetch_interior_'","'sim_prime_width_'"),
        ('Path(previous.__file__),','Path(previous.__file__),Path(template.__file__),'),
        ('Interior fetch-size output cofactor only; exact clip, requests, ownership and cycles unchanged. Canonical FAIL retained.',
         'Early prime-width payload only; checked request authority and cycles unchanged. Canonical and historical aggregate FAIL retained.'),
    ):
        assert text.count(old)==1,old;text=text.replace(old,new)
    return text


def main():
    scope=dict(original.__dict__,__file__=__file__,previous=original,template=template,
               leaf=leaf,recipe=recipe,PARENT_MODEL=PARENT_MODEL,CORE_MODEL=CORE_MODEL,
               CHANGES=CHANGES,evidence=evidence,check_delta=check_delta)
    exec(compile(prepare_source(),__file__,'exec'),scope)
    exec(compile(inspect.getsource(original.main),__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__':raise SystemExit(main())
