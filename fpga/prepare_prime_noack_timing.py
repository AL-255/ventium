#!/usr/bin/env python3
"""Prepare one guarded timing-driven measurement of the tested priming candidate.

Change the diagnostic mapper explicitly, not the clocks or acceptance threshold.
Preserve the closed controller's full native monitor/stop/reap lifecycle. This
producer does not launch Vivado; source-matched PC/CRC/fault checks must close.
"""
import argparse
import ast
import json
import os
from pathlib import Path
import subprocess

from prepare_fragment_exact_timing import sha, replace, span
from freeze_prime_noack_rk_candidate import CHANGES, PARENT, CORE_MODEL

REPO = Path(__file__).resolve().parents[1]
TEMPLATES = {
    'synthesis/run.py': '544b80e623cebd479aa4cd383489fc9752ef82e596f40befea5b8af7a9830ee8',
    'synthesis/audit_closed.py': '352a0de8ca705b3714c6a826ac2160089c060184035f54fa78c7ac39970d0125',
    'clock/run.py': 'ee40f89560f86d2f9ac6198f701873973015bedef22b9c9a66980df01448e877',
    'clock/audit_closed.py': '8841227668dc107fab12da9b0cd2c1594fdb6d596ed8d667386fea5f8cb684c8',
    'clock/audit.tcl': 'f766d944965316620332486e69c5fb5863b1493138ba7f7aa135bd5e30cb970a',
    'after_prepare_synth.py': 'b28d1698339d5fb447b647e91d9e39ed7bc89101cdcf5e7a0fe722d9c7609116',
}
PRIME_FILES = [p.removeprefix('ventium/') for p in CHANGES if '/mem/' not in p]
OWNERS = {
    'ventium-v-carry-cm10-prime-noack-oct12.service': '58f6ed8b5d3a469b8b1d2bb1bff77839',
    'ventium-prime-noack-fault-oct12.service': 'b89a84004704420bb34b8475560daabd',
    'ventium-prime-noack-debug-oct12.service': '2dbeba4937f24dc6af6464d14c7e97db',
    'ventium-prime-noack-same-input-oct12.service': 'c120e7e313e6420fb5f36f55b04cbdff',
    'ventium-prime-noack-lint-oct12.service': '07bb1d97d8f544eca5c2e5a09276d3e8',
}


def require_closed_owner(owner, invocation):
    assert owner == dict(InvocationID=invocation, MainPID='0', SubState='exited',
                         ExecMainStatus='0', Result='success'), owner


PROOF = """core=load_proof('core-r1/prepared.json')
assert core['changes']==PRIME_FILES
assert load_proof('core-r1/build-closed.json')['binary_sha256']==CORE_MODEL
assert all(sha(path)==digest for path,digest in core['pins'].items())
pins.update(core['pins'])
leaf_path=Path(core['leaf'])/'closed.json'
leaf=json.loads(leaf_path.read_text())
assert sha(leaf_path)=='ea81001df15e2e41254152d511f4e543f276af237284926ca3884ff0f7cb5c12'
assert leaf['passed'] and leaf['pins_unchanged'] and not leaf['errors']
assert leaf['rows'][0]['counts']['samples']==6103040
assert leaf['rows'][0]['native_exit']==0 and all(row['native_exit']!=0 for row in leaf['rows'][1:])
pins[str(leaf_path)]=sha(leaf_path)
replay=load_proof('canonical-same-input/closed.json')
assert replay['same_input_regression_passed'] and replay['pins_unchanged'] and not replay['errors']
assert len(replay['rows'])==108 and replay['records']==80800 and not replay['canonical_gate_passed']
for name in ('canonical-same-input','debug-r1','fault-r1','agi-r1','ref-r1'):
    checked=load_proof(name+'/closed.json')
    before=load_proof(name+'/started.json')
    assert checked['pins_unchanged'] and not checked['errors']
    if name!='canonical-same-input': assert checked['passed']
    assert all(sha(path)==digest for path,digest in before['pins'].items())
    pins.update(before['pins'])
for name,accepts in (('agi-r1',12096),('ref-r1',13888)):
    checked=load_proof(name+'/closed.json')
    assert checked['native_exit']==0 and checked['candidate_primes']==accepts
    assert checked['fixture_cases']==20 and checked['paired_v']==2560
    matrix=load_proof(name+'/matrix/result.json')
    inputs=load_proof(name+'/matrix/inputs.json')
    assert matrix['passed'] and matrix['inputs_unchanged'] and not matrix['errors']
    assert all(sha(path)==digest for path,digest in inputs.items())
    pins.update(inputs)
held=load_proof('held-r1/result.json')
assert held['passed'] and held['inputs_unchanged'] and not held['errors'] and len(held['cases'])==48
inputs=load_proof('held-r1/inputs.json')
assert all(sha(path)==digest for path,digest in inputs.items())
pins.update(inputs)
fault=load_proof('fault-r1/closed.json')
assert len(fault['measurements'])==32
assert all(sha(proof/'fault-r1'/path)==digest for path,digest in fault['artifacts'].items())
""".replace('PRIME_FILES', repr(PRIME_FILES)).replace('CORE_MODEL', repr(CORE_MODEL))


def derive(original):
    result = {}
    for name in ('synthesis/run.py', 'clock/run.py'):
        text = original[name]
        for label in ('synth', 'clock'):
            text = text.replace('ventium-mc-pair-srt-'+label+'-oct12.service',
                                'ventium-prime-noack-'+label+'-oct12.service')
        text = replace(text, "manifest['variant'] == 'mc_pair_srt_timing'", "manifest['variant'] == 'prime_noack_timing'")
        text = replace(text, "manifest['source_contract_synthesis_profile'] == 'logic_only'",
                       "manifest['source_contract_synthesis_profile'] == 'balanced'")
        text = replace(text, "VEN_FPGA_BUILD_PROFILE='logic_only'", "VEN_FPGA_BUILD_PROFILE='balanced'")
        if name.startswith('synthesis'):
            text = replace(text,
                '# floor. The source-matched bus cancellation candidate retains the same synthesis profile.',
                '# floor. This candidate changes the mapper; retain the conservative disk bound and live stop floor.')
            text = span(text, "core=load_proof('core-r1/prepared.json')\n", "for name in ('memory-r1'", PROOF)
            text = replace(text, "prepared['changes']==['rtl/core/core.sv','rtl/fpu/fpu_srt_div.sv']",
                           "prepared['changes']=="+repr([p.removeprefix('ventium/') for p in CHANGES]))
            rationale = ('Measure tested same-line ACK and priming cuts using normal timing-driven Default '
                'synthesis at the real 40 MHz constraint. The diagnostic parent used -no_timing_driven; '
                'do not attribute any frequency delta solely to RTL. Preserve UV/fast modes, full P5 caches '
                'and the native resource guard. Canonical FAIL remains unqualified; no route/deployment.')
            text = span(text, '    rationale=', '    generic_gate=', '    rationale='+repr(rationale)+',\n')
        else:
            text = replace(text, 'ventium-mc-read-commit.PNi1O0xm/synthesis-r2', 'ventium-mc-pair-srt.fI8m6eUS/synthesis')
            text = replace(text, '9262331c62aa74413bbf5a785e927fcdea1a425507941bcf1d3f94c449bf8d15',
                           'edeeb26299d0cb2b85e71a1567e09440e566726e544d0c4c084a520d28a93ffd')
        # Resource limits and process ownership handling are not rewritten.
        anchor = 'owner = None\n'
        assert text[text.index(anchor):] == original[name][original[name].index(anchor):]
        for guard in ("VENTIUM_VIVADO_MEMORY_MAX='8G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'",
                      'if free < 4*gib:', 'memory+swap > 13*gib', 'min(host.values()) < 2*gib'):
            assert guard in text
        result[name] = text
    text = original['synthesis/audit_closed.py']
    text = replace(text, 'Audit exactly two timing deltas against the measured MC parent.',
                   'Audit four tested RTL deltas and the explicitly changed synthesis mapper.')
    text = replace(text, 'No new defines, mapper changes, timing waiver or inherited suite acceptance.',
                   'No new defines, clock changes, timing waiver or inherited suite acceptance.')
    text = replace(text, 'ventium-mc-read-commit.PNi1O0xm/synthesis-r2', 'ventium-mc-pair-srt.fI8m6eUS/synthesis')
    text = replace(text, 'ventium-mc-read-commit.PNi1O0xm/fpga-r1', 'ventium-mc-pair-srt.fI8m6eUS/fpga-r1')
    text = replace(text, 'ventium-mc-pair-srt-synth-oct12.service', 'ventium-prime-noack-synth-oct12.service')
    text = replace(text, '8bf3e5b5444b681ed8fa38d936bdb948fa028d6f37c63b47eca6c6e6060be9da', PARENT)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    text = replace(text, 'for folder in (synth,old_synth):',
                   "for folder,expected_mapper in ((synth,mapper.replace(' -no_timing_driven','')),(old_synth,mapper)):")
    text = replace(text, '== [mapper]', '== [expected_mapper]')
    text = replace(text, 'matched_profile_mc_pair_srt_timing=True,',
                   'same_clocks_and_defines=True, synthesis_profile_changed=True, isolated_rtl_gain_claimed=False,')
    result['synthesis/audit_closed.py'] = text
    text = replace(original['clock/audit_closed.py'], 'ventium-mc-pair-srt-clock-oct12.service',
                   'ventium-prime-noack-clock-oct12.service')
    result['clock/audit_closed.py'] = replace(text, '(-8.802)', '(-9.616)')
    result['clock/audit.tcl'] = original['clock/audit.tcl']
    text = original['after_prepare_synth.py']
    text = replace(text, "root==scratch/'ventium-mc-pair-srt.fI8m6eUS'",
                   "root==scratch/'ventium-mc-pair-srt.fI8m6eUS/prime-noack'")
    text = replace(text, "unit='ventium-mc-pair-srt-'+label+'-oct12.service'",
                   "unit='ventium-prime-noack-'+label+'-oct12.service'")
    preflight = """    assert load(root/'soc-r1/coremark/audit.json')['passed']
    assert load(root/'fault-r1/closed.json')['passed']
    assert load(root/'debug-r1/closed.json')['passed']
    assert load(root/'lint-r1/closed.json')['passed']
    model=load(root/'soc-r1/build-closed.json')['binary_sha256']
    manifest=load(root/'fpga-r1/freeze-receipt.json')['manifest_sha256']
    assert sha(root/'fpga-r1/input-manifest.json')==manifest
"""
    text = span(text, "    wait('ventium-mc-pair-srt-resume-r2-oct12.service'",
                "    launch('synth',3100,manifest,model)", preflight)
    # An existing native owner, live or closed, never authorizes a duplicate.
    text = replace(text, "    directory='synthesis' if label=='synth' else 'clock'",
                   "    assert not state(unit)['InvocationID'], ('owner already exists',unit)\n"
                   "    directory='synthesis' if label=='synth' else 'clock'")
    result['after_prepare_synth.py'] = text
    for name, text in result.items():
        if name.endswith('.py'):
            ast.parse(text, filename=name)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.root.resolve(strict=True)
    parent = scratch/'ventium-mc-pair-srt.fI8m6eUS'
    assert __debug__ and root == parent/'prime-noack'
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    manifest = json.loads((root/'fpga-r1/freeze-receipt.json').read_text())['manifest_sha256']
    model = json.loads((root/'soc-r1/build-closed.json').read_text())['binary_sha256']
    assert sha(root/'fpga-r1/input-manifest.json') == manifest
    assert sha(root/'soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == model
    assert json.loads((root/'soc-r1/coremark/audit.json').read_text())['passed']
    owners = {}
    for unit, invocation in OWNERS.items():
        owner = dict(line.split('=', 1) for line in subprocess.check_output([
            'systemctl', '--user', 'show', unit, '-pInvocationID', '-pMainPID',
            '-pSubState', '-pExecMainStatus', '-pResult'], text=True, timeout=10).splitlines())
        require_closed_owner(owner, invocation)
        owners[unit] = owner
    original = {}
    for name, digest in TEMPLATES.items():
        assert sha(parent/name) == digest
        original[name] = (parent/name).read_text()
    outputs = derive(original)
    assert not (root/'timing-prepared.json').exists()
    assert all(not (root/name).exists() for name in outputs)
    for name, text in outputs.items():
        path = root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as stream:
            stream.write(text)
    pins = {str(parent/name): digest for name, digest in TEMPLATES.items()}
    for path in (Path(__file__), REPO/'fpga/prepare_fragment_exact_timing.py',
                 REPO/'fpga/freeze_prime_noack_rk_candidate.py'):
        pins[str(path)] = sha(path)
    receipt = dict(passed=True, controllers_generated_not_launched=True, template_pins=pins,
        prerequisite_native_owners=owners,
        outputs={str(root/name): sha(root/name) for name in outputs}, unchanged_guard_lifecycle=True,
        mapper='Default timing-driven', comparator_mapper='Default -no_timing_driven',
        source_manifest_sha256=manifest, model_sha256=model, canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    with (root/'timing-prepared.json').open('x') as stream:
        json.dump(receipt, stream, indent=2)
    print(json.dumps({k:v for k,v in receipt.items() if k not in ('template_pins','outputs')}))


if __name__ == '__main__':
    main()
