#!/usr/bin/env python3
"""Derive matched, bounded timing controllers; do not launch them here."""
import argparse
import ast
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import sha, replace, span
from freeze_mc_read_commit_rk_candidate import CHANGES, PARENT

REPO=Path(__file__).resolve().parents[1]
TEMPLATES={
    'synthesis/run.py':'50def5fc1e91c6026e169e47030c3eca3576eaecc4105b9656388078a47ca74f',
    'synthesis/audit_closed.py':'a5d33ead9bfe52efa3f405b340544094eb8fa0da22f2140dfe04a5669e66400f',
    'clock/run.py':'9d372f6aeba8abfaca71b5e19c240fc25e448190c0eaf4ed3bf63a065fc49c3b',
    'clock/audit_closed.py':'16b34938a06bf5eed2abad9daed43611752043167912458a480a2b19649802c0',
    'clock/audit.tcl':'f766d944965316620332486e69c5fb5863b1493138ba7f7aa135bd5e30cb970a',
    'after_prepare_synth.py':'2ee635b3a49ab15a915f7ed849de1340885e11473d1c091edd48cab007d551f1',
}
LEAF="""leaf=load_proof('leaf-r2/closed.json')
formal=load_proof('formal-r1/closed.json')
assert leaf['passed'] and leaf['pins_unchanged']
assert [(r['label'],r['native_exit']) for r in leaf['rows']]==[
    ('positive',0),('missing-read-ack',1),('raw-fragment-ack',1),('lost-fp-admission',1)]
assert formal['passed'] and formal['pins_unchanged'] and formal['abstract_predicate_proof']
assert [(r['label'],r['answer']) for r in formal['rows']]==[
    ('positive','unsat'),('missing-read-ack','sat'),('raw-fragment-ack','sat'),
    ('lost-fp-admission','sat'),('allow-store-prime','sat')]
assert all(sha(path)==digest for path,digest in formal['pins'].items())
pins.update(formal['pins'])
held=load_proof('held-r1/result.json')
assert held['passed'] and held['inputs_unchanged'] and not held['errors'] and len(held['cases'])==48
held_pins=load_proof('held-r1/inputs.json')
assert all(sha(path)==digest for path,digest in held_pins.items())
pins.update(held_pins)
branch=load_proof('branch-r1/closed.json')
assert branch['passed'] and branch['pins_unchanged'] and not branch['errors'] and len(branch['measurements'])==160
branch_pins=load_proof('branch-r1/started.json')['pins']
assert all(sha(path)==digest for path,digest in branch_pins.items())
pins.update(branch_pins)
"""


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    ap.add_argument('--freeze-invocation',required=True)
    ap.add_argument('--lint-invocation',required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    root=args.root.resolve(strict=True);parent=scratch/'ventium-pair-ready-cofactor.btYwXlBN'
    assert __debug__ and root==scratch/'ventium-mc-read-commit.PNi1O0xm'
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    for inv in (args.freeze_invocation,args.lint_invocation):
        assert len(inv)==32 and all(c in '0123456789abcdef' for c in inv)
    manifest=json.loads((root/'fpga-r1/freeze-receipt.json').read_text())['manifest_sha256']
    model=json.loads((root/'soc-r1/build-closed.json').read_text())['binary_sha256']
    assert sha(root/'fpga-r1/input-manifest.json')==manifest
    assert sha(root/'soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted')==model
    original={}
    for name,digest in TEMPLATES.items():
        assert sha(parent/name)==digest
        original[name]=(parent/name).read_text()
    result={}
    for name in ('synthesis/run.py','clock/run.py'):
        text=original[name].replace('ventium-pair-ready-','ventium-mc-read-')
        text=replace(text,"manifest['variant'] == 'pair_ready_cofactor'","manifest['variant'] == 'mc_read_commit'")
        if name.startswith('synthesis'):
            text=span(text,"leaf=load_proof('leaf-r2/closed.json')\n","for name in ('memory-r1'",LEAF)
            text=replace(text,"prepared['changes']==['rtl/core/core.sv','rtl/core/core_bus_driver.svh','rtl/mem/ven_l1d.sv']",
                         "prepared['changes']==['rtl/core/core_mem_chain.svh']")
            rationale=('Measure only read-only successor-hint commit against the 30.34809 MHz readiness parent. '
                'One header delta; unchanged definitions, UV+fast mode, full P5 caches, clocks and diagnostic '
                'logic-only mapper. Directed state/cycle and short CoreMark CRC/cycles checked. Canonical '
                'gate remains FAIL; no release, standard-suite, timing or hardware acceptance inherited.')
            text=span(text,'    rationale=','    generic_gate=','    rationale='+repr(rationale)+',\n')
        else:
            text=replace(text,'ventium-fragment-read-payload.etYN56fg','ventium-pair-ready-cofactor.btYwXlBN')
            text=replace(text,'2a61dfded20337c61dd5a7347ad388c59c25a2bd4f2af5c3bbb0fef4cdedcd25',
                         '51832e2844ec3bcd8ad456d3a552a74aae49642fc00e425aa313329e07ea4b99')
        boundary='owner = None\n'
        assert text[text.index(boundary):]==original[name][original[name].index(boundary):]
        for guard in ("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'",
                      'if free < 4*gib:','memory+swap > 13*gib','min(host.values()) < 2*gib'):
            assert guard in text
        result[name]=text
    text=original['synthesis/audit_closed.py']
    text=replace(text,'ventium-fragment-read-payload.etYN56fg','ventium-pair-ready-cofactor.btYwXlBN',2)
    text=replace(text,"ventium-pair-ready-cofactor.btYwXlBN/exact-fpga-r1'","ventium-pair-ready-cofactor.btYwXlBN/fpga-r1'")
    text=replace(text,'ventium-pair-ready-synth-oct11.service','ventium-mc-read-synth-oct11.service')
    text=replace(text,'76b5cf6b0796ed944533430b065208d5b6988adbfc1859efc0bda51abe628855',PARENT)
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(CHANGES)+'\n')
    text=replace(text,'matched_profile_pair_ready_cofactor=True','matched_profile_mc_read_commit=True')
    text=replace(text,'Audit three descriptor/readiness deltas against the measured exact-fragment parent.',
                 'Audit the read-only hint commit against the measured readiness parent.')
    result['synthesis/audit_closed.py']=text
    text=replace(original['clock/audit_closed.py'],'ventium-pair-ready-clock-oct11.service','ventium-mc-read-clock-oct11.service')
    result['clock/audit_closed.py']=replace(text,'(-10.924)','(-7.951)')
    result['clock/audit.tcl']=original['clock/audit.tcl']
    text=replace(original['after_prepare_synth.py'],"root==scratch/'ventium-pair-ready-cofactor.btYwXlBN'",
                 "root==scratch/'ventium-mc-read-commit.PNi1O0xm'")
    text=replace(text,"unit='ventium-pair-ready-'+label","unit='ventium-mc-read-'+label")
    preflight=f"""    wait('ventium-mc-read-soc-queue-oct11.service','c1d3e8724e9a417d8f9c9592cd3b935d',2300)
    wait('ventium-mc-read-freeze-oct11.service',{args.freeze_invocation!r},300)
    wait('ventium-mc-read-lint-oct11.service',{args.lint_invocation!r},400)
    assert load(root/'soc-r1/coremark/audit.json')['passed']
    model=load(root/'soc-r1/build-closed.json')['binary_sha256']
    manifest=load(root/'fpga-r1/freeze-receipt.json')['manifest_sha256']
    assert sha(root/'fpga-r1/input-manifest.json')==manifest
"""
    result['after_prepare_synth.py']=span(text,"    wait('ventium-pair-ready-soc-queue-oct11.service'",
                                         "    launch('synth',3100,manifest,model)",preflight)
    assert not (root/'timing-prepared.json').exists()
    for name,text in result.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
        assert not (root/name).exists()
    for name,text in result.items():
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('x') as f:f.write(text)
    pins={str(parent/name):digest for name,digest in TEMPLATES.items()}
    for p in (Path(__file__),REPO/'fpga/prepare_fragment_exact_timing.py',
              REPO/'fpga/freeze_mc_read_commit_rk_candidate.py'):pins[str(p.resolve())]=sha(p)
    record=dict(passed=True,controllers_generated_not_launched=True,template_pins=pins,
        outputs={str(root/name):sha(root/name) for name in result},unchanged_guard_lifecycle=True,
        source_manifest_sha256=manifest,model_sha256=model,canonical_gate_passed=False,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (root/'timing-prepared.json').open('x') as f:json.dump(record,f,indent=2)
    print(json.dumps({k:v for k,v in record.items() if k not in ('template_pins','outputs')}),flush=True)


if __name__=='__main__':main()
