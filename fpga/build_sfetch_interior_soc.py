"""Transfer the cycle-neutral fetch-size cofactor onto the faster PC parent."""
import inspect
from pathlib import Path
import sys

import build_v_result_carry_soc as previous

REPO=Path(__file__).resolve().parents[1]
ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
sys.path.insert(0,str(REPO/'verif/fe_pipe'))
import build_sfetch_interior_core as leaf
import prepare_sfetch_interior_cofactor as recipe
from run_sfetch_interior_func import MODEL as CORE_MODEL

base=previous.base
sha,load,save,stable=base.sha,base.load,base.save,base.stable
PARENT_MODEL='b32ab4b34482669c03ea57ce7be0dbd475623fa00b00c4c814fec976d75c86d2'
CHANGES=[recipe.FILE]
check_definitions=previous.check_definitions


def check_delta(name,before,after):
    if name==recipe.FILE:
        assert recipe.transform(before.decode()).encode()==after
        return True
    assert before==after,'unreviewed source change: '+name
    return False


def evidence(proof,core):
    assert proof==ROOT and core==ROOT/'sfetch-interior-core-r1'
    pins=leaf.check_leaf(proof/'sfetch-interior-leaf-r1')
    boundary=proof/'sfetch-interior-boundary-r1'
    start,done=load(boundary/'started.json'),load(boundary/'closed.json')
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert (len(done['rows']),done['candidate_records'],done['paired_v'])==(88,21832,4968)
    assert start['pins'][str(core/'obj/tb_ventium')]==CORE_MODEL
    pins.update(start['pins'])
    for p in boundary.rglob('*'):
        if p.is_file():pins[str(p)]=sha(p)
    for name,audit_name in (('sfetch-interior-func-r1','audit.json'),
                            ('sfetch-interior-demand-r1','cycle-audit.json')):
        root=proof/name; audit=load(root/audit_name)
        assert audit['passed'] and audit['model']==CORE_MODEL
        assert not audit['canonical_gate_passed'] and not audit['standard_suite']
        if name.endswith('func-r1'):
            assert (audit['functional_passes'],audit['functional_records'],audit['v_retirements'])==(108,80800,30132)
            assert audit['unmasked_functional_passes']==105
            assert audit['unmasked_failures']==['tx_regform','tx_regform2','tx_stack']
            pins.update(audit['pins'])
        else:
            assert (audit['identical_stream_pairs'],audit['candidate_cycle_records'],audit['actual_v_retirements'])==(192,15200,384)
            assert audit['cycle_delta_percent']==0
            pins.update(load(root/'started.json')['pins'])
        pins.update(audit['artifacts']);pins[str(root/audit_name)]=sha(root/audit_name)
    gate=load(core/'verify-closed.json')
    assert gate['canonical_gate_native_exit']==2 and not gate['canonical_gate_passed']
    assert gate['pins_unchanged'] and not gate['masks_or_goldens_or_bands_changed']
    assert len(gate['deltas'])==20 and all(r['same_records'] for r in gate['deltas'])
    pins.update(load(core/'verify-started.json')['pins'])
    for p in (core/'verify-started.json',core/'verify-closed.json',Path(previous.__file__)):
        pins[str(p.resolve())]=sha(p)
    assert stable(pins)
    return pins


def prepare_source():
    assert sha(previous.__file__)=='42cc3af8ab1d8ac7ca25f50d44c5e63a89ff5ac46705ba1c5c476b5597cee529'
    text=inspect.getsource(previous.prepare)
    for old,new in (
        ("assert old['directed_model']==leaf.MODEL and old['parent_profile']=='pipe-wait'",
         "assert old['directed_model']==leaf.MODEL and old['changes']==['rtl/core/core.sv','rtl/core/core_fetch_decode.svh']"),
        ("'sim_v_result_carry_'","'sim_sfetch_interior_'"),
        ('Path(recipe.__file__),Path(leaf.__file__),',
         'Path(recipe.__file__),Path(leaf.__file__),Path(previous.__file__),'),
        ('Only V arithmetic result loses carry input; original flag CF and all execution authority retained.',
         'Interior fetch-size output cofactor only; exact clip, requests, ownership and cycles unchanged. Canonical FAIL retained.'),
    ):
        assert text.count(old)==1,old;text=text.replace(old,new)
    return text


def main():
    scope=dict(previous.__dict__,__file__=__file__,previous=previous,leaf=leaf,recipe=recipe,
               PARENT_MODEL=PARENT_MODEL,CORE_MODEL=CORE_MODEL,CHANGES=CHANGES,
               evidence=evidence,check_delta=check_delta)
    exec(compile(prepare_source(),__file__,'exec'),scope)
    exec(compile(inspect.getsource(previous.main),__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__':raise SystemExit(main())
