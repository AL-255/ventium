"""Freeze matched response-mux synthesis/timing controllers; launch nothing.

Preserve the native parent's complete process lifecycle and resource admission.
This diagnostic measurement does not waive red gates or authorize deployment.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_response_kind_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

SCRATCH = Path('/home/yukidama/external/tmp').resolve(strict=True)
ROOT = SCRATCH/'ventium-data-size.v2HaTO2X'
MANIFEST = 'a904bc49994af1079b1ae68b35e8aad00578e68eb7a3f9886f7515e60eaf4240'
MODEL = 'cebca505c43333e40092fd5e2de78ab6adaa589fdaeb1d7e002c54860329f304'
PARENT_MANIFEST = '9e53127a928b0044465174583cb7ed87abc8da1d7644056054d3ceeeb5688bbb'
PARENT_DCP = '5c0ee4195b9331cf7eb31b022b86753feecd892cd3cff78cc1448c717b4b6557'
CHANGES = {'ventium/rtl/mem/ven_l1d.sv':
           'afda9d01a2d95f90f156c9b4f725e27644eaa14fd1f2262090c0423540f2e369'}
TEMPLATES = {
    'prefix-payload-synthesis-r1/run.py': '1a7334a35898a0752c0b02c0c6a1c743d15c9daac18054f567cba1bf0469f949',
    'prefix-payload-synthesis-r1/audit_closed.py': '836279ac216094ed57390fabfaef955d33a2839ab48b560d4b1db2557fc8b6d7',
    'prefix-payload-clock-r1/run.py': '048d633e4833a7fe86c49911077a0d0e90dab2524c261a47881dc1ce9587745c',
    'prefix-payload-clock-r1/audit_closed.py': 'df520086d20eba834e32b0579f256dbd06bb39eeee2236e005b120d27f363355',
    'prefix-payload-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
LEAF_PROOF = '''leaf=load_proof('response-kind-leaf-r2/closed.json')
assert sha(proof/'response-kind-leaf-r2/closed.json')=='0fe4f4fbcad383c4017cf5cc003e08358c539e7b1939f847d0297d7db88b41f0'
assert leaf['passed'] and leaf['pins_unchanged'] and not leaf['errors']
assert not leaf['sequential_cache'] and not leaf['whole_core'] and not leaf['timing_verified']
mutants=['reverse_kind','lost_primary_owner','lost_early_strobes','lost_stream']
names=['control-preprocess','candidate-preprocess','positive-build','positive']
for name in mutants: names += [name+'-build',name]
names += ['formal-positive','formal-reverse_kind','formal-lost_stream']
assert [r['name'] for r in leaf['rows']]==names
assert len(leaf['rows'])==15 and all(r['child_reaped'] and r['child_affinity']==[12] for r in leaf['rows'])
assert all(r['native_exit']==int(r['name'] in mutants) for r in leaf['rows'])
pins.update(leaf['pins'])
for path,digest in leaf['artifacts'].items():
    p=proof/'response-kind-leaf-r2'/path
    assert sha(p)==digest
    pins[str(p)]=digest
for row in leaf['rows']:
    path=proof/'response-kind-leaf-r2'/(row['name']+'.log')
    assert sha(path)==row['log_sha256']
assert 'RESPONSE-KIND-OK vectors=262144 ' in (proof/'response-kind-leaf-r2/positive.log').read_text()
assert (proof/'response-kind-leaf-r2/formal-positive.log').read_text().strip()=='unsat'
assert all((proof/'response-kind-leaf-r2'/('formal-'+n+'.log')).read_text().strip()=='sat'
           for n in ('reverse_kind','lost_stream'))
assert all('RESPONSE-KIND-DATA' in (proof/'response-kind-leaf-r2'/(n+'.log')).read_text() for n in mutants)
# Unfiltered independent regrade retains both the reference timeout and the
# unresolved finite-CS cases. They are not turned into acceptance passes.
fault_audit=load_proof('response-kind-fault-audit.json')
assert fault_audit['evidence_audit_passed'] and fault_audit['fault_full_comparisons']==88
assert fault_audit['fault_records']==35124 and fault_audit['fault_paired_v']==4580
assert not fault_audit['first_fault_run_passed'] and not fault_audit['boundary_full_gate_passed']
assert fault_audit['boundary_reference_failures']==8 and fault_audit['boundary_full_comparisons']==88
assert fault_audit['boundary_rtl_executions']==176 and fault_audit['boundary_candidate_v']==428
assert fault_audit['boundary_complete_state_and_cycle_equal']
assert not fault_audit['physical_board'] and not fault_audit['standard_suite']
pins.update(fault_audit['artifact_pins'])
boundary=load_proof('response-kind-boundary-r1/closed.json')
assert sha(proof/'response-kind-boundary-r1/closed.json')=='6c41bba8c3acab780365b6692e1087216e722f0a585a44e918d114057e6c86ad'
assert not boundary['passed'] and len(boundary['errors'])==8 and boundary['all_children_reaped']
'''


def common(text):
    return (text.replace('prefix-payload-', 'response-kind-')
            .replace('prefix_payload_timing', 'response_kind_timing')
            .replace('build_prefix_payload_soc', 'build_response_kind_soc'))


def baseline(text):
    return replace(text,
        'baseline_gameplay_ipc=0.51186266,baseline_window=[1700065237,1800065237]',
        'baseline_gameplay_ipc=0.50430455,baseline_window=[1800065237,1900065237]')


def derive(original):
    outputs = {}
    old = original['prefix-payload-synthesis-r1/run.py']
    text = baseline(common(old))
    text = replace(text,
        'e16799c98385d94ddae7d4cb7296a56cf207ec0f3b43110058a0d03d841c02e8',
        '4648943aee67781f71aef0813a860aae478c0c2aad1b12fc4eea7f7a8c0075e7')
    text = replace(text,
        'Measure equivalent register-prefix memory-payload isolation; no route or deployment.',
        'Measure exact response-kind mux factoring; no route or deployment.')
    assert text.count('response-kind-env-fault-r1') == 3
    text = text.replace('response-kind-env-fault-r1', 'response-kind-env-fault-r2')
    text = span(text, "leaf=load_proof('response-kind-leaf-r1/closed.json')",
                "system=load_proof('response-kind-system-r2/closed.json')", LEAF_PROOF)
    text = text.replace('response-kind-system-r2', 'response-kind-system-r1')
    text = replace(text, 'ventium-response-kind-system-oct14-r2.service',
                         'ventium-response-kind-system-oct14-r1.service')
    text = replace(text,
        'e7707265d23fdbf8b780a9324b5a6d3ebed439beeb2f23748fa34f38852a374f',
        'f07b26993db709d911bee003ca64479fb5efca0c6b73d0ca34561c0b33501b91')
    text = span(text, '    rationale=', '    generic_gate=',
        "    rationale='Factor exact code/data response mux arms before the late request-kind select. Target the measured 36.591166892 MHz fetch-to-writeback path. One L1 source delta; no state, latency, defines, cache geometry or transport change. Source-extracted leaf and mutants, arbitrary-data SMT contract, complete core/system/fetch/fault replays and unchanged short CoreMark CRC clocks are retained. Canonical and finite-CS gates remain failed; no timing, standard-suite or hardware pass is inherited.',\n")
    guarded(text, old)
    first, last = 'host = available()\n', "(root/'once').mkdir()"
    assert text[text.index(first):text.index(last)] == old[old.index(first):old.index(last)]
    outputs['response-kind-synthesis-r1/run.py'] = text

    old = original['prefix-payload-clock-r1/run.py']
    text = baseline(common(old))
    text = replace(text, str(ROOT/'fast-segment-synthesis-r2'), str(ROOT/'prefix-payload-synthesis-r1'))
    text = replace(text, '8d41c9b7cbeb543c9d72b253e53ca15de204200229d4517efe73b2d6ca7176b0', PARENT_DCP)
    clock_guarded(text, old)
    outputs['response-kind-clock-r1/run.py'] = text

    text = common(original['prefix-payload-synthesis-r1/audit_closed.py'])
    for before, after in (('fast-segment-synthesis-r2', 'prefix-payload-synthesis-r1'),
                          ('fast-segment-fpga-r1', 'prefix-payload-fpga-r1')):
        text = replace(text, str(ROOT/before), str(ROOT/after))
    text = replace(text, 'd4122ecbed950b845654bec8060fa83b96213f07b373b002604704cea06b6f7e', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    text = replace(text, 'one-include prefix-payload transfer', 'one-file response-kind mux transfer')
    outputs['response-kind-synthesis-r1/audit_closed.py'] = text
    text = common(original['prefix-payload-clock-r1/audit_closed.py'])
    outputs['response-kind-clock-r1/audit_closed.py'] = replace(text, '(-3.189)', '(-2.329)')
    outputs['response-kind-clock-r1/audit.tcl'] = original['prefix-payload-clock-r1/audit.tcl']
    for name, text in outputs.items():
        if name.endswith('.py'):
            ast.parse(text, filename=name)
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    root = parser.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == SCRATCH
    source = root/'response-kind-fpga-r1'
    assert sha(source/'input-manifest.json') == MANIFEST
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    assert set(manifest['changed_parent_payloads']) == set(CHANGES)
    assert sha(root/'response-kind-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    for name, digest in CHANGES.items():
        assert sha(source/name) == digest
        assert native.transform(name.removeprefix('ventium/'),
            (root/'prefix-payload-fpga-r1'/name).read_text()) == (source/name).read_text()
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
    receipt = root/'response-kind-timing-prepared.json'
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
    print('Guarded response-kind controllers prepared; nothing launched.', flush=True)


if __name__ == '__main__':
    main()
