"""Prepare fresh owners for an unchanged synthesis after a launch-affinity error.

No RTL, feature, timing, resource limit or timeout change. Retain R1's failed
receipts; never reuse its once marker, controller, project or output files.
"""
import ast
import hashlib
import json
import os
from pathlib import Path
import subprocess

TEMPLATES = {
    'window-current-synthesis-r1/run.py': '34bcfc388b8d120a7c8187cf359780e1cbca3fbaa4fd7ee1f0a5446516ad13f7',
    'window-current-synthesis-r1/audit_closed.py': 'e535c9fb721a354ab5b66fd7d3bffa16017e3b23704a6fed9052f3e717b4ba2a',
    'window-current-clock-r1/run.py': 'fd5ba09c2d9c9d94efa2f54342f633b3b4e5905b4da1996643c91e7a80ca1726',
    'window-current-clock-r1/audit_closed.py': 'fc967f7bf8b268a37461ad06fa83b6b77fa72f73ce0bec1e401c1edff74fd4c8',
    'window-current-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
RENAME = {
    'ventium-window-current-synth-oct13.service': 'ventium-window-current-synth-oct13-r2.service',
    'ventium-window-current-clock-oct13.service': 'ventium-window-current-clock-oct13-r2.service',
    'window-current-synthesis-r1': 'window-current-synthesis-r2',
    'window-current-clock-r1': 'window-current-clock-r2',
}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = scratch/'ventium-data-size.v2HaTO2X'
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    closed = json.loads((root/'window-current-synthesis-r1/closed.json').read_text())
    assert closed['native_exit'] == 124 and closed['inputs_unchanged']
    assert closed['resource_stop'] is None and closed['controller_failure'] is None
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    owner = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', 'ventium-window-current-synth-oct13.service',
        '-pMainPID', '-pSubState', '-pExecMainStatus', '-pInvocationID'], text=True).splitlines())
    assert owner == dict(MainPID='0', SubState='failed', ExecMainStatus='1',
                         InvocationID='f124e2fdd07344ce99447cbef6fdbee3')
    outputs, pins = {}, {str(Path(__file__).resolve()): sha(__file__)}
    for name, digest in TEMPLATES.items():
        source = root/name
        assert sha(source) == digest
        old = source.read_text()
        new = old
        target = name
        for before, after in RENAME.items():
            new, target = new.replace(before, after), target.replace(before, after)
        reverse = new
        for before, after in reversed(list(RENAME.items())):
            reverse = reverse.replace(after, before)
        assert reverse == old, 'non-owner/non-path change'
        if name.endswith('.py'): ast.parse(new)
        assert not (root/target).exists()
        pins[str(source)] = digest
        outputs[target] = new
    assert len(outputs) == 5
    for name, text in outputs.items():
        path = root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as stream: stream.write(text)
    with (root/'window-current-retry-prepared.json').open('x') as stream:
        json.dump(dict(pins=pins, outputs={p: sha(root/p) for p in outputs},
            original_owner=owner, rtl_changed=False, model_changed=False,
            guards_and_deadlines_unchanged=True, recommended_cpus=[16,17,18,19],
            controller_created_not_launched=True, native_failure_retained=True,
            gameplay_ipc=None, timing_mhz=None, hardware_acceptance=False), stream, indent=2)
    print('Prepared fresh unchanged-input synthesis/report owners; no native tool launched.')


if __name__ == '__main__': main()
