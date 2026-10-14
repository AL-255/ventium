"""Retry disk-refused admission under a fresh identity, with identical guards."""
import ast
import json
import os
from pathlib import Path
import subprocess

import prepare_response_kind_synthesis as first

TEMPLATES = {
    'response-kind-synthesis-r1/run.py': 'b31cd977d984bda411e238c5bdedaf6dcd2a3b75e776cf1f5646c860709e7d29',
    'response-kind-synthesis-r1/audit_closed.py': '97b49bb3d1420dde2b080b84d228eca4b48a6861cd8a5183132c5df53ebb471c',
    'response-kind-clock-r1/run.py': '4b3aae02ea8e546d0394d3d2d939c1fdd34276da72f2407582d7d616906e7175',
    'response-kind-clock-r1/audit_closed.py': 'cc8c69a577f887ea8bb38f9d4d5dbb8201e1f2c6f37458e785c18533326c0ca9',
    'response-kind-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
RENAMES = [('response-kind-'+kind+'-r1', 'response-kind-'+kind+'-r2')
           for kind in ('synthesis', 'clock')]
RENAMES += [('ventium-response-kind-'+kind+'-oct14-r1.service',
             'ventium-response-kind-'+kind+'-oct14-r2.service') for kind in ('synth', 'clock')]
RENAMES += [('response-kind-timing-prepared.json', 'response-kind-timing-prepared-r2.json')]


def derive(original):
    output = {}
    for name, text in original.items():
        new = text
        for before, after in RENAMES:
            name = name.replace(before, after)
            new = new.replace(before, after)
        if name.endswith('.py'): ast.parse(new)
        if name.endswith('run.py'):
            guard = first.clock_guarded if '-clock-' in name else first.guarded
            guard(new, text)
            lo, hi = 'host = available()\n', "(root/'once').mkdir()"
            assert new[new.index(lo):new.index(hi)] == text[text.index(lo):text.index(hi)]
        output[name] = new
    return output


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == first.SCRATCH
    root = first.ROOT
    unit = 'ventium-response-kind-synth-oct14-r1.service'
    state = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', unit, '-pMainPID', '-pSubState',
        '-pExecMainStatus', '-pInvocationID'], text=True).splitlines())
    assert state == dict(MainPID='0', SubState='failed', ExecMainStatus='1',
                         InvocationID='cad6b0cfb13246cb8b3506180951844d')
    log = subprocess.check_output(['journalctl', '--user', '-u', unit, '--no-pager'], text=True)
    assert 'assert shutil.disk_usage(root).free-4*gib > 2*measured_disk_growth' in log
    assert not (root/'response-kind-synthesis-r1/once').exists()
    assert not (root/'response-kind-synthesis-r1/started.json').exists()
    pins, original = {}, {}
    for name, digest in TEMPLATES.items():
        path = root/name
        assert first.sha(path) == digest
        original[name] = path.read_text(); pins[str(path)] = digest
    old = root/'response-kind-timing-prepared.json'
    assert first.sha(old) == 'fb365559035e62f758e09b839a923f32a7193fd29acc5a0e9407202f92bf7505'
    receipt = json.loads(old.read_text())
    pins.update(receipt['template_pins'])
    for path in (old, Path(__file__).resolve(), Path(first.__file__).resolve()):
        pins[str(path)] = first.sha(path)
    assert all(first.sha(Path(path)) == digest for path, digest in pins.items())
    output = derive(original)
    target = root/'response-kind-timing-prepared-r2.json'
    assert not target.exists() and all(not (root/name).exists() for name in output)
    for name, text in output.items():
        path = root/name; path.parent.mkdir(exist_ok=True)
        with path.open('x') as stream: stream.write(text)
    receipt.update(template_pins=pins, outputs={str(root/n): first.sha(root/n) for n in output},
        previous_admission=dict(owner=state, journal=log, vivado_launched=False,
                                failure='insufficient twice-measured-growth disk reserve'))
    with target.open('x') as stream: json.dump(receipt, stream, indent=2)
    print('Fresh retry identities prepared; original failed admission retained; nothing launched.')


if __name__ == '__main__': main()
