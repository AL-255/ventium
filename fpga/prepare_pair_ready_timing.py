#!/usr/bin/env python3
"""Derive one bounded, source-matched synthesis/audit sequence, without launching it.

Preserve the completed predecessor's native lifecycle, resource reserves and
exclusive launcher verbatim. Only candidate identities, proof set and measured
parent change. The diagnostic mapper is matched; 40 MHz is not assumed.
"""
import argparse
import ast
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import sha, replace, span
from freeze_pair_ready_rk_candidate import CHANGES, PARENT

REPO = Path(__file__).resolve().parents[1]
TEMPLATES = {
    'synthesis/run.py':'dd9f533604287fa08738db37cce8ca977e8054e4dbb117d92c315fe8682bcd71',
    'synthesis/audit_closed.py':'8c9ccf6813a33ef0c318ce42ecbde6161a1cdb878a43f0b7b415f551cdb61977',
    'clock/run.py':'58078008041410ec4a51e8661a1b6d5fb0181d52963da5fe15dad7e8d36b3f68',
    'clock/audit_closed.py':'6ff3ab3861ad4414ebf179a8cea66390db3c1f0b2bba385d4a495cfd942fa26c',
    'clock/audit.tcl':'f766d944965316620332486e69c5fb5863b1493138ba7f7aa135bd5e30cb970a',
    'after_prepare_synth.py':'26a1b2aed82785ed0a233a01588d4abf7743e12dbfb2d86ff77d3b21448c100e',
}
MANIFEST='2d573cb347eaa630a7010f197d2ee0788f2aeef8340c6bb24d06767dd9712ece'
MODEL='6583d6577f3099fe0e84bf52762516300843a8c1658f5cc373ec8c2240dcc090'

PROOF='''proof = root.parent
def load_proof(relative):
    path=proof/relative
    pins[str(path)]=sha(path)
    return json.loads(path.read_text())
verify=load_proof('core-r1/verify-closed.json')
assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']
assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
assert len(verify['deltas'])==20 and all(row['same_records'] for row in verify['deltas'])
leaf=load_proof('leaf-r2/closed.json')
assert leaf['passed'] and leaf['pins_unchanged'] and not leaf['errors']
assert len(leaf['rows'])==7 and sum(not r['mutant'] for r in leaf['rows'])==6
assert all(sha(path)==digest for path,digest in leaf['pins'].items())
for name in ('memory-r1','store-r1','fp-r1/matrix'):
    checked=load_proof(name+'/closed.json')
    before=load_proof(name+'/started.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert len(checked['measurements'])==288
    assert all(sha(path)==digest for path,digest in before['pins'].items())
prepared=load_proof('soc-r1/prepared.json')
assert len(prepared['intersecting_rtl_sources'])==102
assert prepared['changes']==['rtl/core/core.sv','rtl/core/core_bus_driver.svh','rtl/mem/ven_l1d.sv']
assert all(sha(path)==digest for path,digest in prepared['pins'].items())
load_proof('timing-prepared.json')
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--lint-invocation',required=True)
    args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    root=args.root.resolve(strict=True)
    parent=scratch/'ventium-fragment-read-payload.etYN56fg'
    assert __debug__ and root==scratch/'ventium-pair-ready-cofactor.btYwXlBN'
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert len(args.lint_invocation)==32 and all(c in '0123456789abcdef' for c in args.lint_invocation)
    assert sha(root/'fpga-r1/input-manifest.json')==MANIFEST
    assert sha(root/'soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted')==MODEL
    original={}
    for name,digest in TEMPLATES.items():
        assert sha(parent/name)==digest
        original[name]=(parent/name).read_text()
    result={}
    for name in ('synthesis/run.py','clock/run.py'):
        text=original[name]
        text=replace(text,"source = root.parent/'exact-fpga-r1'","source = root.parent/'fpga-r1'")
        text=text.replace('ventium-fragment-exact-','ventium-pair-ready-')
        text=replace(text,"manifest['variant'] == 'fragment_exact_payload'","manifest['variant'] == 'pair_ready_cofactor'")
        text=replace(text,"root.parent/'exact-lint-r1/closed.json'","root.parent/'lint-r1/closed.json'")
        if name.startswith('synthesis'):
            text=span(text,'proof = root.parent\n',"cmroot=root.parent/'exact-soc-r1/coremark'",PROOF)
            text=replace(text,"cmroot=root.parent/'exact-soc-r1/coremark'","cmroot=root.parent/'soc-r1/coremark'")
            rationale=('Measure paired-readiness cofactoring plus descriptor-width correctness against the '
                '27.83654 MHz exact-fragment parent. Three explicit RTL deltas; same 156 definitions, '
                'UV+fast mode, full P5 caches, clocks and diagnostic logic-only mapper. Directed state/cycle '
                'matrices and short CoreMark CRC/cycles pass. Canonical gate remains FAIL; no release, '
                'standard-suite, timing or hardware acceptance is inherited.')
            text=span(text,'    rationale=','    generic_gate=','    rationale='+repr(rationale)+',\n')
        else:
            text=replace(text,'ventium-bus-cancel-payload.Fzx7hUyD','ventium-fragment-read-payload.etYN56fg')
            text=replace(text,'26b3ffc95c25b1ac211827eed1d5561710b3f32e4f969d0af8cf0d3ff9583577',
                         '2a61dfded20337c61dd5a7347ad388c59c25a2bd4f2af5c3bbb0fef4cdedcd25')
        boundary='owner = None\n'
        assert text[text.index(boundary):]==original[name][original[name].index(boundary):]
        for invariant in ("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'",
            'if free < 4*gib:','memory+swap > 13*gib','min(host.values()) < 2*gib'):
            assert invariant in text
        result[name]=text
    text=original['synthesis/audit_closed.py']
    text=replace(text,"source = root.parent / 'exact-fpga-r1'","source = root.parent / 'fpga-r1'")
    text=replace(text,'ventium-bus-cancel-payload.Fzx7hUyD','ventium-fragment-read-payload.etYN56fg',2)
    text=replace(text,"ventium-fragment-read-payload.etYN56fg/fpga'","ventium-fragment-read-payload.etYN56fg/exact-fpga-r1'")
    text=replace(text,'ventium-fragment-exact-synth-oct11.service','ventium-pair-ready-synth-oct11.service')
    text=replace(text,'9fe0c951a57d41826a4383055d3bbbf63cb6b7bb16936a400be9741792fb9536',PARENT)
    text=replace(text,"expected_changes={'ventium/rtl/core/core.sv':'a6c2c5aabddc268ae2be5b1896d1a9bc6f8780d17eb4e45c62c2f651c48a5cae'}",
                 'expected_changes='+repr(CHANGES))
    text=replace(text,'matched_profile_fragment_exact_payload=True','matched_profile_pair_ready_cofactor=True')
    text=replace(text,'Audit the one-core fragment change against the measured BUS parent.',
                 'Audit three descriptor/readiness deltas against the measured exact-fragment parent.')
    result['synthesis/audit_closed.py']=text
    text=original['clock/audit_closed.py']
    text=replace(text,'ventium-fragment-exact-clock-oct11.service','ventium-pair-ready-clock-oct11.service')
    result['clock/audit_closed.py']=replace(text,'(-10.582)','(-10.924)')
    result['clock/audit.tcl']=original['clock/audit.tcl']
    text=original['after_prepare_synth.py']
    text=replace(text,"root==scratch/'ventium-fragment-read-payload.etYN56fg'",
                 "root==scratch/'ventium-pair-ready-cofactor.btYwXlBN'")
    text=replace(text,"unit='ventium-fragment-exact-'+label","unit='ventium-pair-ready-'+label")
    preflight="""    wait('ventium-pair-ready-soc-queue-oct11.service','b172564a5ba04239b3dab9b8196ab6dd',2300)
    wait('ventium-pair-ready-freeze-oct11.service','e18dcd7d19e74518b99ca344b82a9bec',300)
    wait('ventium-pair-ready-lint-oct11.service',LINT_INVOCATION,400)
    assert load(root/'soc-r1/coremark/audit.json')['passed']
    model=load(root/'soc-r1/build-closed.json')['binary_sha256']
    manifest=load(root/'fpga-r1/freeze-receipt.json')['manifest_sha256']
    assert sha(root/'fpga-r1/input-manifest.json')==manifest
""".replace('LINT_INVOCATION',repr(args.lint_invocation))
    result['after_prepare_synth.py']=span(text,"    wait('ventium-fragment-exact-freeze-oct11.service'",
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
              REPO/'fpga/freeze_pair_ready_rk_candidate.py'):pins[str(p.resolve())]=sha(p)
    record=dict(passed=True,controllers_generated_not_launched=True,template_pins=pins,
        outputs={str(root/name):sha(root/name) for name in result},
        unchanged_guard_lifecycle=True,source_manifest_sha256=MANIFEST,model_sha256=MODEL,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (root/'timing-prepared.json').open('x') as f:json.dump(record,f,indent=2)
    print(json.dumps({k:v for k,v in record.items() if k not in ('template_pins','outputs')}),flush=True)


if __name__=='__main__':main()
