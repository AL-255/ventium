"""Prepare an identity-only clock-audit retry after R1 failed RAM admission.

Does not launch Vivado or change resource, timing, source or closure checks.
The failed R1 owner and its files remain intact; synthesis is never restarted.
"""
import argparse
import ast
import json
import os
from pathlib import Path
import subprocess

from prepare_fragment_exact_timing import sha

ROOT_NAME = 'ventium-fprem-sequence.iSZ9BAj4'
OLD_UNIT = 'ventium-demand-size-clock-oct15-r1.service'
NEW_UNIT = 'ventium-demand-size-clock-oct15-r2.service'
OLD_INVOCATION = 'f259d735df564873b2d2b2ef9fcb3949'
HASHES = {
    'run.py': '8ecbe9a75382b363cfca2cc40b6bba576b17280b3b27ed4adbae2013c03a21f0',
    'audit_closed.py': 'c88dab8e46c3830bf567db20be8191823292d3df223853a2db0b30ee2b3d0f4c',
    'audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def derive(original):
    import hashlib
    if set(original) != set(HASHES):
        raise ValueError('exact original controller set required')
    result = {}
    for name, digest in HASHES.items():
        text = original[name]
        if hashlib.sha256(text.encode()).hexdigest() != digest:
            raise ValueError('original controller drift: ' + name)
        if name.endswith('.py'):
            if text.count(OLD_UNIT) != 1:
                raise ValueError('ambiguous owner identity: ' + name)
            text = text.replace(OLD_UNIT, NEW_UNIT)
            ast.parse(text, filename=name)
        result[name] = text
    return result


def state(unit):
    return dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', unit, '-p', 'InvocationID', '-p', 'MainPID',
        '-p', 'SubState', '-p', 'Result', '-p', 'ExecMainStatus'],
        text=True, timeout=10).splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    root = parser.parse_args().root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == scratch / ROOT_NAME
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    old = root / 'demand-size-clock-r1'
    new = root / 'demand-size-clock-r2'
    receipt = root / 'demand-size-clock-r2-prepared.json'
    assert not new.exists() and not receipt.exists()
    failed = state(OLD_UNIT)
    assert failed == dict(InvocationID=OLD_INVOCATION, MainPID='0',
                         SubState='failed', Result='exit-code', ExecMainStatus='1')
    assert set(p.name for p in old.iterdir()) == set(HASHES), 'R1 launched native work'
    assert not state(NEW_UNIT)['InvocationID'], 'R2 owner already exists'
    chain = state('ventium-demand-size-timing-chain-oct15-r1.service')
    assert chain['InvocationID'] == 'aa9a95ce0ddf4e3b8b757f272163da8c'
    assert chain['MainPID'] == '0' and chain['SubState'] == 'failed'
    synth = state('ventium-demand-size-synth-oct15-r1.service')
    assert synth == dict(InvocationID='690da7de4b1f4ed79bef83ab80db0a47',
                        MainPID='0', SubState='exited', Result='success', ExecMainStatus='0')
    closed = json.loads((root / 'demand-size-synthesis-r1/closed.json').read_text())
    audit = json.loads((root / 'demand-size-synthesis-r1/audit.json').read_text())
    assert closed['native_exit'] == 0 and closed['inputs_unchanged']
    assert not closed['controller_failure'] and not closed['resource_stop']
    assert audit['passed'] and audit['no_oom']
    original = {name: (old / name).read_text() for name in HASHES}
    output = derive(original)
    # Preserve the native failed preflight, not a synthesized success receipt.
    journal = subprocess.check_output(['journalctl', '--user',
        '_SYSTEMD_INVOCATION_ID=' + OLD_INVOCATION, '--no-pager', '-o', 'cat'],
        text=True, timeout=10)
    assert 'AssertionError: 8+2 RAM and 4+4 swap admission' in journal
    new.mkdir()
    for name, text in output.items():
        with (new / name).open('x') as stream:
            stream.write(text)
    result = dict(prepared_not_launched=True, original_owner=failed,
        original_failure_journal=journal, closed_synthesis_owner=synth,
        original_pins={str(old / name): digest for name, digest in HASHES.items()},
        outputs={str(new / name): sha(new / name) for name in output},
        preparer_sha256=sha(Path(__file__)), new_unit=NEW_UNIT,
        synthesis_restarted=False, resource_limits_unchanged=True,
        report_tcl_unchanged=True, gameplay_ipc=None, hardware_acceptance=False)
    with receipt.open('x') as stream:
        json.dump(result, stream, indent=2)
    print('R2 clock audit prepared, not launched; original 10 GiB RAM admission retained.')


if __name__ == '__main__':
    main()
