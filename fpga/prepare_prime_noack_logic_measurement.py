#!/usr/bin/env python3
"""Prepare a matched-mapper diagnostic after the timing optimizer's guarded stop.

Reuse the immutable, tested RTL export. Explicitly override only its mapper at
launch, and recheck the logic-only Tcl contract. No weakened clocks, memory/disk
guards, feature exclusions, implementation launch or inherited acceptance.
"""
import argparse
import ast
import json
import os
from pathlib import Path
import subprocess

from prepare_fragment_exact_timing import sha as hash_path, replace, span
from prepare_prime_noack_clock_r2 import NEW_GUARD, state

REPO = Path(__file__).resolve().parents[1]
SYNTH_INV = '6e13bd65df494c51a2044dbab264380f'
QUEUE_INV = '1694e645b24e4e529c0c663ad5c6441a'
STOP_SHA = 'f9d1e7e114673fe6a528d623ffe4098a55fa5fcc938e0f05d1a01b820b8f688c'
SYNTH = 'ventium-prime-noack-logic-synth-oct12.service'
CLOCK = 'ventium-prime-noack-logic-clock-oct12.service'
LOGIC_GUARD = NEW_GUARD.replace('ne "" ||', 'ne "-no_timing_driven" ||').replace(
    'Default timing-driven synthesis', 'Default logic-only diagnostic synthesis')


def sha(path):
    return hash_path(Path(path))


def validate_stop(start, closed, samples, owner, queue):
    assert owner == dict(InvocationID=SYNTH_INV, MainPID='0', SubState='failed',
                         ExecMainStatus='1', Result='exit-code'), owner
    assert queue == dict(InvocationID=QUEUE_INV, MainPID='0', SubState='failed',
                         ExecMainStatus='1', Result='exit-code'), queue
    assert start['controller_invocation'] == SYNTH_INV
    assert closed['native_exit'] == 143 and closed['inputs_unchanged']
    assert closed['resource_stop'] == 'combined scope memory early stop'
    assert closed['controller_failure'] is None and not closed['implementation_started']
    assert start['memory_max'] == 8*2**30 and start['swap_max'] == 6*2**30
    assert start['combined_early_stop'] == 13*2**30
    assert samples and all(not r['events'][name] for r in samples
                           for name in ('oom', 'oom_kill', 'oom_group_kill'))
    assert all(r['reason'] is None for r in samples[:-1])
    assert samples[-1]['reason'] == closed['resource_stop']
    assert samples[-1]['memory'] + samples[-1]['swap'] > start['combined_early_stop']


def derive(original):
    outputs = {}
    for key, destination in (('synthesis/run.py', 'synthesis-logic-r1/run.py'),
                             ('clock-r2/run.py', 'clock-logic-r1/run.py')):
        before = original[key]
        text = before.replace('ventium-prime-noack-synth-oct12.service', SYNTH)
        text = text.replace('ventium-prime-noack-clock-r2-oct12.service', CLOCK)
        text = replace(text, "VEN_FPGA_BUILD_PROFILE='balanced'", "VEN_FPGA_BUILD_PROFILE='logic_only'")
        # Keep the immutable manifest's balanced contract truthful. The new
        # preparation receipt separately proves the explicit mapper override.
        assert "manifest['source_contract_synthesis_profile'] == 'balanced'" in text
        if key.startswith('synthesis'):
            text = replace(text, "load_proof('timing-prepared.json')",
                "load_proof('timing-prepared.json')\n"
                "logic_prepared=load_proof('logic-measurement-prepared.json')\n"
                "assert logic_prepared['logic_only_contract_passed']\n"
                "assert all(sha(p)==h for p,h in logic_prepared['pins'].items())\n"
                "pins.update(logic_prepared['pins'])")
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Matched Default -no_timing_driven diagnostic of the tested ACK/priming cuts. "
                "Balanced mapper stopped at 13 GiB, without OOM. Same frozen RTL, 40/100 MHz clocks, "
                "156 definitions, full P5 caches and resource guards. No route/deployment or gate waiver.',\n")
        else:
            text = replace(text, "synthesis = root.parent/'synthesis'", "synthesis = root.parent/'synthesis-logic-r1'")
        boundary = 'owner = None\n'
        assert text[text.index(boundary):] == before[before.index(boundary):]
        for guard in ("VENTIUM_VIVADO_MEMORY_MAX='8G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'",
                      'if free < 4*gib:', 'memory+swap > 13*gib', 'min(host.values()) < 2*gib',
                      "VEN_FPGA_CORE_MHZ='40'"):
            assert guard in text
        outputs[destination] = text
    text = original['synthesis/audit_closed.py']
    text = replace(text, 'four tested RTL deltas and the explicitly changed synthesis mapper',
                   'four tested RTL deltas under the matched diagnostic synthesis mapper')
    text = replace(text, 'ventium-prime-noack-synth-oct12.service', SYNTH)
    text = replace(text, "((synth,mapper.replace(' -no_timing_driven','')),(old_synth,mapper))",
                   '((synth,mapper),(old_synth,mapper))')
    text = replace(text, 'synthesis_profile_changed=True, isolated_rtl_gain_claimed=False,',
                   'synthesis_profile_changed=False, isolated_rtl_gain_claimed=False, matched_mapper=True,')
    outputs['synthesis-logic-r1/audit_closed.py'] = text
    outputs['clock-logic-r1/audit_closed.py'] = replace(original['clock-r2/audit_closed.py'],
        'ventium-prime-noack-clock-r2-oct12.service', CLOCK)
    outputs['clock-logic-r1/audit.tcl'] = replace(original['clock-r2/audit.tcl'], NEW_GUARD, LOGIC_GUARD)
    text = original['after_prepare_synth.py']
    text = replace(text, "work=root/'timing-queue';", "work=root/'timing-queue-logic-r1';")
    text = replace(text, "unit='ventium-prime-noack-'+label+'-oct12.service'",
                   "unit='ventium-prime-noack-logic-'+label+'-oct12.service'")
    text = replace(text, "directory='synthesis' if label=='synth' else 'clock'",
                   "directory='synthesis-logic-r1' if label=='synth' else 'clock-logic-r1'")
    text = text.replace("root/'synthesis/", "root/'synthesis-logic-r1/")
    text = text.replace("root/'clock/", "root/'clock-logic-r1/")
    assert "assert not state(unit)['InvocationID']" in text
    outputs['after_prime_logic.py'] = text
    for name, text in outputs.items():
        if name.endswith('.py'):
            ast.parse(text, filename=name)
    return outputs


def prepare(root):
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == scratch/'ventium-mc-pair-srt.fI8m6eUS/prime-noack'
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    load = lambda path: json.loads(path.read_text())
    prior = root/'synthesis'
    assert sha(prior/'closed.json') == STOP_SHA
    started, closed = load(prior/'started.json'), load(prior/'closed.json')
    samples = [json.loads(row) for row in (prior/'watch.jsonl').read_text().splitlines()]
    owner = state('ventium-prime-noack-synth-oct12.service')
    queue = state('ventium-prime-noack-report-queue-r2-oct12.service')
    validate_stop(started, closed, samples, owner, queue)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    scope = state('ventium-vivado.scope')
    assert scope['SubState'] == 'dead' and not scope['InvocationID']
    for unit in (SYNTH, CLOCK, 'ventium-prime-noack-clock-r2-oct12.service'):
        assert not state(unit)['InvocationID'], ('already attempted', unit)
    synth = prior/'native-synthesis/rk_ao486_system/rk_ao486_system.runs/synth_1'
    assert not (synth/'rk_ao486_bd_wrapper.dcp').exists()
    assert not (synth/'__synthesis_is_complete__').exists()
    assert 'Start Timing Optimization' in (synth/'runme.log').read_text()
    assert 'synth_design completed successfully' not in (synth/'runme.log').read_text()
    pins = dict(started['pins'])
    for receipt in ('timing-prepared.json', 'clock-repair-prepared.json'):
        record = load(root/receipt)
        pins.update(record.get('template_pins', {}))
        pins.update(record.get('original_pins', {}))
        pins.update(record['outputs'])
        pins[str(root/receipt)] = sha(root/receipt)
    for path in (Path(__file__), REPO/'fpga/prepare_fragment_exact_timing.py',
                 REPO/'fpga/prepare_prime_noack_clock_r2.py',
                 REPO/'fpga/test_code_payload_rk_wrapper.tcl', prior/'started.json',
                 prior/'closed.json', prior/'watch.jsonl', synth/'runme.log',
                 root/'timing-queue-clock-r2/closed.json'):
        pins[str(path.resolve())] = sha(path)
    assert all(sha(p) == h for p, h in pins.items())
    source = root/'fpga-r1'
    contract = subprocess.run(['tclsh', str(REPO/'fpga/test_code_payload_rk_wrapper.tcl'),
        str(source/'ventium/fpga/create_project_3mhz_wrapper.tcl'), str(source/'flow'),
        str(source/'defines.txt'), str(source/'ventium'), str(source/'template'), 'logic_only'],
        capture_output=True, text=True, timeout=15)
    assert contract.returncode == 0, contract.stdout+contract.stderr
    assert 'exact156defs' in contract.stdout and 'POSTED-DDR-SOURCE-CONTRACT-OK' in contract.stdout
    originals = {name: (root/name).read_text() for name in (
        'synthesis/run.py', 'synthesis/audit_closed.py', 'clock-r2/run.py',
        'clock-r2/audit_closed.py', 'clock-r2/audit.tcl', 'after_prepare_synth.py')}
    outputs = derive(originals)
    receipt = root/'logic-measurement-prepared.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in outputs)
    assert all(sha(p) == h for p, h in pins.items())
    for name, text in outputs.items():
        path = root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as f:
            f.write(text)
    result = dict(passed=True, controllers_generated_not_launched=True, pins=pins,
        outputs={str(root/n): sha(root/n) for n in outputs}, stopped_owner=owner,
        stopped_queue=queue, native_exit=closed['native_exit'], no_recorded_oom=True,
        stop_seconds=closed['seconds'], stop_peak_memory=closed['peak_memory_bytes'],
        stop_peak_swap=closed['peak_swap_bytes'], failed_run_has_completed_checkpoint=False,
        source_manifest_sha256=sha(source/'input-manifest.json'), unchanged_source_payloads=190,
        source_contract_profile='balanced', explicit_measurement_profile='logic_only',
        logic_only_contract_passed=True, logic_only_contract_output=contract.stdout,
        unchanged_monitor_lifecycle=True, synthesized_40mhz_requirement_met=False,
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    with receipt.open('x') as f:
        json.dump(result, f, indent=2)
    return {k:v for k,v in result.items() if k not in ('pins', 'outputs', 'logic_only_contract_output')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    print(json.dumps(prepare(parser.parse_args().root.resolve(strict=True))))
