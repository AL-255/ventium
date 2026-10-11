#!/usr/bin/env python3
"""Derive bounded synthesis/report controllers from the closed BUS experiment.

Only source/proof identities and labels change. Preserve the exclusive launcher,
hard resource caps, admission reserves, monitor, timeout and stop/reap logic.
No controller is launched here. All generated code and its template are pinned.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
TEMPLATES = {
    'synthesis/run.py':'0b8482258b10a95950c75be23663314b33dbaa4cb6bd66ab14bc8c4984cbac26',
    'synthesis/audit_closed.py':'d1c8ddb815c85e51fd1fb3487e373c34e9a04c9b9a5b37bd023587ae497d81d8',
    'clock/run.py':'3cd90c3f81b84ba61ee2a6f969c2d6bd20f8368213ee8c6b8dd873bdc01997fc',
    'clock/audit_closed.py':'07e04eb1bc0b467f75f4c465cdd8b4c8d18b9f4878b5de5142d195253536ac98',
    'clock/audit.tcl':'f766d944965316620332486e69c5fb5863b1493138ba7f7aa135bd5e30cb970a',
}
MANIFEST = '76b5cf6b0796ed944533430b065208d5b6988adbfc1859efc0bda51abe628855'
MODEL = 'c52a221ecdc0ada4671c8f8d9e27bfd1be441a85b11cabcc610999f33ed75d75'
CORE = 'a6c2c5aabddc268ae2be5b1896d1a9bc6f8780d17eb4e45c62c2f651c48a5cae'


def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def replace(text, before, after, count=1):
    assert text.count(before) == count, ('template drift', before[:90], text.count(before), count)
    return text.replace(before, after)


def span(text, first, last, replacement):
    assert text.count(first) == text.count(last) == 1
    a,b=text.index(first),text.index(last); assert a<b
    return text[:a]+replacement+text[b:]


PROOF = '''proof = root.parent
def load_proof(relative):
    path=proof/relative
    pins[str(path)]=sha(path)
    return json.loads(path.read_text())
verify=load_proof('exact-core-r1/verify-closed.json')
assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']
assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
assert len(verify['deltas'])==20 and all(row['same_records'] for row in verify['deltas'])
replay=load_proof('exact-canonical-ab-r1/closed.json')
assert replay['same_input_regression_passed'] and replay['pins_unchanged'] and not replay['errors']
assert len(replay['rows'])==108 and replay['records']==80800
for relative in ('exact-system-r1/closed.json','exact-bus-r1/closed.json',
                 'exact-fp-r1/matrix/closed.json','exact-smm-r1/closed.json','exact-rep-smi-r1/closed.json'):
    checked=load_proof(relative)
    assert checked['passed'] and checked['pins_unchanged']
broad=load_proof('exact-system-broad-r1/closed.json')
assert not broad['passed'] and broad['pins_unchanged'] and len(broad['measurements'])==36
assert {(row['case'],row['latency'],row['error']) for row in broad['errors']} == {
    (name,latency,'complete parent/candidate state or cycle difference')
    for name in ('pxfrag','pxc04','pxc04e') for latency in (0,7)}
prepared=load_proof('exact-soc-r1/prepared.json')
assert prepared['broad_architectural_streams_identical'] and not prepared['broad_equivalence_gate_passed']
assert len(prepared['broad_cycle_deltas'])==18 and all(row['clock_delta']<=0 for row in prepared['broad_cycle_deltas'])
assert all(sha(path)==digest for path,digest in prepared['pins'].items())
load_proof('timing-prepared.json')
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True);args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    root=args.root.resolve(strict=True); parent=scratch/'ventium-bus-cancel-payload.Fzx7hUyD'
    assert __debug__ and root==scratch/'ventium-fragment-read-payload.etYN56fg'
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert sha(root/'exact-fpga-r1/input-manifest.json')==MANIFEST
    assert sha(root/'exact-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted')==MODEL
    original={}
    for name,digest in TEMPLATES.items():
        assert sha(parent/name)==digest
        original[name]=(parent/name).read_text()
    queue=parent/'after_prepare_synth.py'
    # The queue's exact source is preserved in the preparation receipt too.
    result={}
    for name in ('synthesis/run.py','clock/run.py'):
        text=original[name]
        text=replace(text,"source = root.parent/'fpga'", "source = root.parent/'exact-fpga-r1'")
        text=text.replace('ventium-bus-cancel-', 'ventium-fragment-exact-')
        text=replace(text,"manifest['variant'] == 'bus_cancel_payload'", "manifest['variant'] == 'fragment_exact_payload'")
        text=replace(text,"root.parent/'lint/closed.json'", "root.parent/'exact-lint-r1/closed.json'")
        if name.startswith('synthesis'):
            text=span(text,"for relative in ('core-audit.json'", "cmroot=root.parent/'soc/coremark'", PROOF)
            text=replace(text,"cmroot=root.parent/'soc/coremark'", "cmroot=root.parent/'exact-soc-r1/coremark'")
            rationale='Measure the byte-exact fragment payload successor to the 28.10410 MHz BUS parent. Exactly one core.sv delta; same 156 definitions, UV+fast mode, full P5 caches, clocks and logic-only mapper. Directed architectural and actual AXI-byte checks pass; broad cycle differences from removing excess reads remain reported. Canonical gate remains FAIL; this is timing diagnosis, not standard-suite or physical acceptance.'
            text=span(text,'    rationale=', '    generic_gate=', '    rationale='+repr(rationale)+',\n')
        else:
            text=replace(text,'ventium-u-shift-registers.XRngKRoW','ventium-bus-cancel-payload.Fzx7hUyD')
            text=replace(text,'190d758a5817c8c9727553035a62dd4075281762545444feed346e67454134f2',
                         '26b3ffc95c25b1ac211827eed1d5561710b3f32e4f969d0af8cf0d3ff9583577')
        # Retain the entire monitored process lifecycle verbatim, not just caps.
        boundary='owner = None\n'
        assert text[text.index(boundary):]==original[name][original[name].index(boundary):]
        for invariant in ('VENTIUM_VIVADO_MEMORY_MAX=\'8G\'', 'VENTIUM_VIVADO_MEMORY_SWAP_MAX=\'6G\'',
                          "if free < 4*gib:", "memory+swap > 13*gib", "min(host.values()) < 2*gib"):
            assert invariant in text
        result[name]=text
    text=original['synthesis/audit_closed.py']
    text=replace(text,"source = root.parent / 'fpga'", "source = root.parent / 'exact-fpga-r1'")
    text=text.replace('ventium-u-shift-registers.XRngKRoW','ventium-bus-cancel-payload.Fzx7hUyD')
    text=replace(text,'ventium-bus-cancel-synth-oct11.service','ventium-fragment-exact-synth-oct11.service')
    text=replace(text,'a36e00e8b30b6cfed198e8522c0baa338b528eb490d01e4d0d183f8ec053935e',
                 '9fe0c951a57d41826a4383055d3bbbf63cb6b7bb16936a400be9741792fb9536')
    text=replace(text,"expected_changes={'ventium/rtl/core/core_bus_driver.svh':'e892403371c601c2e2c2660565fb8d4bf8ed7408efe3c0bf271015da63bf7ba1'}",
                 "expected_changes={'ventium/rtl/core/core.sv':"+repr(CORE)+'}')
    text=replace(text,'matched_profile_bus_cancel_payload=True','matched_profile_fragment_exact_payload=True')
    text=replace(text,'Audit the one-header bus cancellation change against the measured shift parent.',
                 'Audit the one-core fragment change against the measured BUS parent.')
    result['synthesis/audit_closed.py']=text
    text=original['clock/audit_closed.py']
    text=replace(text,'ventium-bus-cancel-clock-oct11.service','ventium-fragment-exact-clock-oct11.service')
    text=replace(text,'(-12.659)','(-10.582)')
    result['clock/audit_closed.py']=text
    result['clock/audit.tcl']=original['clock/audit.tcl']
    text=queue.read_text()
    text=replace(text,"root==scratch/'ventium-bus-cancel-payload.Fzx7hUyD'", "root==scratch/'ventium-fragment-read-payload.etYN56fg'")
    text=text.replace("unit='ventium-bus-cancel-'+label", "unit='ventium-fragment-exact-'+label")
    begin="    wait('ventium-bus-cancel-fpga-prepare-r2-oct11.service'"
    end="    launch('synth',3100,manifest,model)"
    preparation='''    wait('ventium-fragment-exact-freeze-oct11.service','e5812444df534c71b3f9aa4ad0d5b99b',300)
    wait('ventium-fragment-exact-lint-oct11.service','02aff51431cf4fa78d19468408208029',400)
    wait('ventium-v-carry-cm10-fragment-exact-oct11.service','41d29ff820a74e8a87ffbb197c439456',1400)
    run('coremark-audit',['python3','-B',repo/'fpga/audit_v_carry_payload_coremark.py',
        '--soc',root/'exact-soc-r1','--unit','ventium-v-carry-cm10-fragment-exact-oct11.service'])
    assert load(root/'exact-soc-r1/coremark/audit.json')['passed']
    model=load(root/'exact-soc-r1/build-closed.json')['binary_sha256']
    manifest=load(root/'exact-fpga-r1/freeze-receipt.json')['manifest_sha256']
    assert sha(root/'exact-fpga-r1/input-manifest.json')==manifest
'''
    result['after_prepare_synth.py']=span(text,begin,end,preparation)
    assert not (root/'timing-prepared.json').exists()
    for name,text in result.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
        path=root/name;assert not path.exists()
    for name,text in result.items():
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('x') as stream:stream.write(text)
    pins={str(parent/name):digest for name,digest in TEMPLATES.items()}
    pins.update({str(queue):sha(queue),str(Path(__file__).resolve()):sha(Path(__file__).resolve())})
    record=dict(passed=True,controllers_generated_not_launched=True,template_pins=pins,
        outputs={str(root/name):sha(root/name) for name in result},
        unchanged_guard_lifecycle=True,source_manifest_sha256=MANIFEST,model_sha256=MODEL,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (root/'timing-prepared.json').open('x') as stream:json.dump(record,stream,indent=2)
    print(json.dumps({k:v for k,v in record.items() if k not in ('template_pins','outputs')}),flush=True)


if __name__=='__main__':main()
