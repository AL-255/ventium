"""Prepare matched segment-admission synthesis; preserve native guard policy.

Only proof/source identities and the immediate-parent comparison change.
The generated controllers neither route nor program the FPGA.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_fast_segment_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

SCRATCH = Path('/home/yukidama/external/tmp').resolve(strict=True)
ROOT = SCRATCH / 'ventium-data-size.v2HaTO2X'
MANIFEST = 'd4122ecbed950b845654bec8060fa83b96213f07b373b002604704cea06b6f7e'
MODEL = '93315731b334cfe12ced52ba1dda186907480a30584e56bb7389d5f3bc123924'
PARENT_MANIFEST = '8f4cf7b06c4368cf888300300513a2835fe7bd678e192b48839bebdb00fe1523'
PARENT_DCP = '8aaea5943daa2337ee404c466ec20ad95efb2198c6f4d79a22547580f6bfa92c'
CHANGES = {'ventium/rtl/core/core.sv':
           '238cd9f713cc6e84a6881cb5e06b8ff341a90cb428be8882b1f1b2d974491ac4'}
TEMPLATES = {
    'way-banked-synthesis-r1/run.py': '953a9a522dfd72ad82c0ea9cb55c23e553f67e4d0596f7f98d1ac3b20d4d533a',
    'way-banked-synthesis-r1/audit_closed.py': 'b9770419affc3ce62ed8675576b37b00ad152e491e2beeababe0056eae446d87',
    'way-banked-clock-r1/run.py': '36594842174209705b495c1cbc8727db6b4627a4b9a564ddd68e85d84386fb97',
    'way-banked-clock-r1/audit_closed.py': '7b2f60673805b99026529e633b95b15d24a7206d1cd80ba8cad642b0331dbf45',
    'way-banked-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
PROOFS = '''leaf=load_proof('fast-segment-leaf-r1/closed.json')
assert sha(proof/'fast-segment-leaf-r1/closed.json')=='35e92836a1b51fc4c259833104873e07e982412c84c9ec45ffb56d1c2a3d097e'
assert leaf['passed'] and leaf['pins_unchanged'] and not leaf['errors']
assert leaf['queries']==[dict(name=n,result=r) for n,r in (
    ('equivalence','unsat'),('wrong-segment','sat'),('expand-down','sat'),
    ('inclusive-page','sat'),('word-boundary','sat'))]
assert len(leaf['rows'])==8
for row in leaf['rows']:
    assert row['build_exit']==0
    assert row['native_exit']==(0 if row['name'] in ('positive','flat-only','load-only','disabled') else 1)
    pins.update(row['artifacts'])
pins.update(leaf['pins'])
system=load_proof('fast-segment-system-r2/closed.json')
assert sha(proof/'fast-segment-system-r2/closed.json')=='a30de9aeb360b8c276037fa561bd2c147f996eceef313a62071afcb439dffcf9'
assert system['passed'] and system['pins_unchanged'] and not system['errors']
assert len(system['rows'])==5 and all(r['passed'] and len(r['rows'])==6 for r in system['rows'])
assert all(r['native']['native_exit']==133 and r['native']['actual_wait'] and
    r['native']['affinity_observed'] and r['counts']['backing_acks']>0
    for case in system['rows'] for r in case['rows'])
system_start=load_proof('fast-segment-system-r2/started.json')
pins.update(system_start['pins'])
for path in (proof/'fast-segment-system-r2').rglob('*'):
    if path.is_file(): pins[str(path)]=sha(path)
system_owner=dict(line.split('=',1) for line in subprocess.check_output([
    'systemctl','--user','show','ventium-fast-segment-system-oct14-r2.service',
    '-pInvocationID','-pSubState','-pMainPID','-pExecMainStatus'],text=True).splitlines())
assert system_owner==dict(InvocationID=system_start['invocation'],SubState='exited',MainPID='0',ExecMainStatus='0')
'''


def common(text):
    return (text.replace('way-banked-', 'fast-segment-')
            .replace('way_banked_timing', 'fast_segment_timing')
            .replace('build_way_banked_soc', 'build_fast_segment_soc'))


def baseline(text):
    return replace(text,
        'baseline_gameplay_ipc=0.51027341,baseline_window=[1200065237,1300065237]',
        'baseline_gameplay_ipc=0.50607097,baseline_window=[1300065237,1400065237]')


def derive(original):
    outputs = {}
    old = original['way-banked-synthesis-r1/run.py']
    text = baseline(common(old))
    text = replace(text,
        'bf17a9053431218ff69194286ab1a91ed3434196ec51e2d78ea9cd5e10e60c96',
        'efcc3318f5c3af9a5926da23a206af9e06f9edbe5c321769564efff4c0e37232')
    text = replace(text,
        'Measure explicit tag-way RAM inference and the equivalent fetch-page cut; no route or deployment.',
        'Measure equivalent parallel fast-memory segment admission; no route or deployment.')
    text = replace(text, "pc=load_proof('fast-segment-soc-r1/build-closed.json')",
                   PROOFS + "pc=load_proof('fast-segment-soc-r1/build-closed.json')")
    text = span(text, '    rationale=', '    generic_gate=',
        "    rationale='Factor segment attributes/full limits before late selection and use constant DS limits in the already-DS-only bounded arm. Exactly one RTL file, no added cycle/state/define or cache change. Target the measured 34.495843251 MHz EIP-to-ESP path through fast-memory admission; downstream request/ACK logic remains. Retain symbolic/native counterexamples, exact system/fetch/fault/private-QEMU comparisons and unchanged short CoreMark cycles. Measure full-chip Fmax/area; canonical, full-suite and physical acceptance remain open.',\n")
    guarded(text, old)
    first, last = 'host = available()\n', "(root/'once').mkdir()"
    assert text[text.index(first):text.index(last)] == old[old.index(first):old.index(last)]
    outputs['fast-segment-synthesis-r1/run.py'] = text

    old = original['way-banked-clock-r1/run.py']
    text = baseline(common(old))
    text = replace(text, str(ROOT/'fp-compare-synthesis-r1'), str(ROOT/'way-banked-synthesis-r1'))
    text = replace(text, '8b312897be7efeee639cf4f85856e081347f13e1dd8a608dc3843986933443a1', PARENT_DCP)
    clock_guarded(text, old)
    outputs['fast-segment-clock-r1/run.py'] = text

    text = common(original['way-banked-synthesis-r1/audit_closed.py'])
    for suffix in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(ROOT/('fp-compare-'+suffix)), str(ROOT/('way-banked-'+suffix)))
    text = replace(text, '296ff7367ef6af0324c47a09615f09f2c02a700a3de411efc617f598c03c001b', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    text = replace(text, 'two-file way-bank/fetch-page transfer', 'one-file segment-admission transfer')
    outputs['fast-segment-synthesis-r1/audit_closed.py'] = text
    text = common(original['way-banked-clock-r1/audit_closed.py'])
    outputs['fast-segment-clock-r1/audit_closed.py'] = replace(text, '(-5.859)', '(-3.989)')
    outputs['fast-segment-clock-r1/audit.tcl'] = original['way-banked-clock-r1/audit.tcl']
    for name, text in outputs.items():
        if name.endswith('.py'):
            ast.parse(text, filename=name)
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    root = parser.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == SCRATCH
    source = root/'fast-segment-fpga-r1'
    assert sha(source/'input-manifest.json') == MANIFEST
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    assert set(manifest['changed_parent_payloads']) == set(CHANGES)
    assert sha(root/'fast-segment-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    for name, digest in CHANGES.items():
        assert sha(source/name) == digest
        assert native.transform(name.removeprefix('ventium/'),
            (root/'way-banked-fpga-r1'/name).read_text()) == (source/name).read_text()
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        path = root/name
        assert sha(path) == digest
        original[name] = path.read_text()
        pins[str(path)] = digest
    for path in (Path(__file__), Path(native.__file__), native.original, Path(native.recipe.__file__),
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py'),
                 Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(path.resolve())] = sha(path)
    outputs = derive(original)
    receipt = root/'fast-segment-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in outputs)
    for name, text in outputs.items():
        path = root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as stream:
            stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n): sha(root/n) for n in outputs},
            source_manifest_sha256=MANIFEST, model_sha256=MODEL, canonical_gate_passed=False,
            standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None), stream, indent=2)
    print('Guarded fast-segment controllers prepared; nothing launched.', flush=True)


if __name__ == '__main__':
    main()
