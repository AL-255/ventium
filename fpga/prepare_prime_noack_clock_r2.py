#!/usr/bin/env python3
"""Repair only the downstream clock reporter; never restart live synthesis.

The first derived clock Tcl retained the diagnostic parent's mapper guard.
Keep its pinned files unchanged and generate a new reporter/observer instead.
"""
import argparse
import ast
import json
import os
from pathlib import Path
import subprocess

from prepare_fragment_exact_timing import sha, replace, span

OLD_QUEUE = 'ventium-prime-noack-timing-queue-oct12.service'
SYNTH = 'ventium-prime-noack-synth-oct12.service'
SYNTH_INV = '6e13bd65df494c51a2044dbab264380f'
NEW_CLOCK = 'ventium-prime-noack-clock-r2-oct12.service'
OLD_GUARD = '''if {[get_property {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} $synth] ne "-no_timing_driven"} {
    error "not the requested logic-only synthesis"
}'''
NEW_GUARD = '''if {[get_property {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} $synth] ne "" ||
    [get_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE $synth] ne "Default"} {
    error "not the requested Default timing-driven synthesis"
}'''


def derive(original):
    result = {'clock-r2/audit.tcl': replace(original['clock/audit.tcl'], OLD_GUARD, NEW_GUARD)}
    for name in ('run.py', 'audit_closed.py'):
        before = original['clock/'+name]
        after = replace(before, 'ventium-prime-noack-clock-oct12.service', NEW_CLOCK)
        if name == 'run.py':
            boundary = 'owner = None\n'
            assert before[before.index(boundary):] == after[after.index(boundary):]
        result['clock-r2/'+name] = after
    queue = original['after_prepare_synth.py']
    queue = replace(queue, "work=root/'timing-queue';", "work=root/'timing-queue-clock-r2';")
    queue = queue.replace("root/'clock/", "root/'clock-r2/")
    queue = replace(queue, "    unit='ventium-prime-noack-'+label+'-oct12.service'",
                    "    assert label=='clock', 'report-only continuation cannot launch synthesis'\n"
                    "    unit="+repr(NEW_CLOCK))
    queue = replace(queue, "    directory='synthesis' if label=='synth' else 'clock'", "    directory='clock-r2'")
    preflight = """    assert state(OLD_QUEUE)['MainPID']=='0'
    wait(SYNTH,SYNTH_INV,3100)
    assert load(root/'soc-r1/coremark/audit.json')['passed']
    assert load(root/'lint-r1/closed.json')['passed']
    model=load(root/'soc-r1/build-closed.json')['binary_sha256']
    manifest=load(root/'fpga-r1/freeze-receipt.json')['manifest_sha256']
    assert sha(root/'fpga-r1/input-manifest.json')==manifest
""".replace('OLD_QUEUE', repr(OLD_QUEUE)).replace('SYNTH_INV', repr(SYNTH_INV)).replace('SYNTH', repr(SYNTH))
    queue = span(queue, "    assert load(root/'soc-r1/coremark/audit.json')['passed']",
                 "    run('synthesis-audit'", preflight)
    queue = replace(queue, "root/'clock/audit.json'", "root/'clock-r2/audit.json'") if "root/'clock/audit.json'" in queue else queue
    assert "launch('synth'" not in queue
    assert "root/'clock/" not in queue
    result['after_clock_repair.py'] = queue
    for name, text in result.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return result


def state(unit):
    return dict(row.split('=', 1) for row in subprocess.check_output([
        'systemctl', '--user', 'show', unit, '-pInvocationID', '-pMainPID',
        '-pSubState', '-pExecMainStatus', '-pResult'], text=True, timeout=10).splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    root = parser.parse_args().root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == scratch/'ventium-mc-pair-srt.fI8m6eUS/prime-noack'
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    prepared = json.loads((root/'timing-prepared.json').read_text())
    assert all(sha(Path(p)) == h for p, h in prepared['outputs'].items())
    assert all(sha(Path(p)) == h for p, h in prepared['template_pins'].items())
    stopped = state(OLD_QUEUE)
    assert stopped['MainPID'] == '0' and stopped['SubState'] in ('dead', 'failed')
    assert stopped['InvocationID'] in ('', '98cc568af1054e95a54f4fb29010251f')
    assert not Path('/proc/2694734').exists()
    assert json.loads((root/'timing-queue/started.json').read_text())['invocation'] == '98cc568af1054e95a54f4fb29010251f'
    synth = state(SYNTH)
    assert synth['InvocationID'] == SYNTH_INV
    assert synth['SubState'] == 'running' and synth['MainPID'] != '0'
    for unit in ('ventium-prime-noack-clock-oct12.service', NEW_CLOCK):
        assert not state(unit)['InvocationID'], ('clock already attempted', unit)
    assert not (root/'synthesis/audit.json').exists()
    originals = {name: (root/name).read_text() for name in (
        'clock/run.py', 'clock/audit_closed.py', 'clock/audit.tcl', 'after_prepare_synth.py')}
    outputs = derive(originals)
    assert all(not (root/name).exists() for name in outputs)
    receipt_path = root/'clock-repair-prepared.json'
    assert not receipt_path.exists()
    for name, text in outputs.items():
        p = root/name; p.parent.mkdir(parents=True, exist_ok=True)
        with p.open('x') as f: f.write(text)
    pins = {str(root/name): sha(root/name) for name in originals}
    pins[str(Path(__file__).resolve())] = sha(Path(__file__))
    result = dict(passed=True, controllers_generated_not_launched=True,
        original_pins=pins, outputs={str(root/n): sha(root/n) for n in outputs},
        stopped_queue=stopped, still_live_synthesis=synth, synthesis_restarted=False,
        correction='Candidate mapper guard: empty MORE OPTIONS and Default directive; all report commands unchanged.',
        unchanged_monitor_lifecycle=True, canonical_gate_passed=False, standard_suite=False,
        hardware_acceptance=False, gameplay_ipc=None)
    with receipt_path.open('x') as f: json.dump(result, f, indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('original_pins','outputs')}))


if __name__ == '__main__':
    main()
