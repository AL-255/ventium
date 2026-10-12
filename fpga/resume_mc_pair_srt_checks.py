#!/usr/bin/env python3
"""Resume after the terminal receipt-key bug, without rerunning closed checks.

Canonical failure is retained. This runs PC diagnostics, export and strict core
lint only; it cannot start Vivado, deploy hardware or grant suite acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback

REPO = Path(__file__).resolve().parents[1]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def check_replay(receipt):
    # This producer deliberately distinguishes A/B equivalence from the still
    # failing canonical gate. Do not replace this with a generic "passed" key.
    assert receipt['same_input_regression_passed'] is True
    assert receipt['pins_unchanged'] is True and receipt['errors'] == []
    assert len(receipt['rows']) == len({row['case'] for row in receipt['rows']}) == 108
    assert all(row['passed'] is True for row in receipt['rows'])
    assert sum(row['records'] for row in receipt['rows']) == receipt['records']
    assert receipt['canonical_gate_passed'] is False


def state(unit):
    return dict(row.split('=', 1) for row in subprocess.check_output([
        'systemctl', '--user', 'show', unit, '-pInvocationID', '-pSubState',
        '-pMainPID', '-pExecMainStatus', '-pResult'], text=True, timeout=10).splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.root.resolve(strict=True)
    assert __debug__ and root == scratch/'ventium-mc-pair-srt.fI8m6eUS'
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    out = root/'resume-r2'
    out.mkdir()

    def save(name, value):
        with (out/name).open('x') as stream:
            json.dump(value, stream, indent=2)

    pins = {str(path): sha(path) for path in (Path(__file__),
        root/'after_checks.py', root/'after_pc_export.py',
        root/'pc-queue-r1/started.json', root/'pc-queue-r1/closed.json',
        root/'export-queue-r1/started.json', root/'export-queue-r1/closed.json',
        root/'canonical-same-input/started.json', root/'canonical-same-input/closed.json',
        root/'soc-r1/prepared.json', root/'core-r1/verify-closed.json',
        REPO/'fpga/build_mc_pair_srt_soc.py', REPO/'fpga/build_pair_ready_soc.py',
        REPO/'fpga/run_v_carry_payload_coremark.py', REPO/'fpga/audit_v_carry_payload_coremark.py',
        REPO/'fpga/freeze_mc_pair_srt_rk_candidate.py', REPO/'fpga/lint_frozen_rk_core.py')}
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID']))
    result = dict(passed=False, errors=[], owners=[], canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None,
        no_synthesis_or_implementation=True)

    def stable():
        return all(sha(path) == digest for path, digest in pins.items())

    def launch(unit, argv, limit):
        assert stable()
        # A transient observation failure never authorizes a duplicate launch.
        assert not state(unit)['InvocationID'], ('owner already exists', unit)
        command = ['systemd-run', '--user', '--unit='+unit, '--remain-after-exit',
            '--property=MemoryMax=3G', '--property=MemorySwapMax=0', '--property=TasksMax=2048',
            '--property=RuntimeMaxSec='+str(limit), '--property=TimeoutStopSec=60',
            '--property=KillMode=control-group', '--property=LimitCORE=0',
            '--working-directory='+str(REPO), '--setenv=TMPDIR=/home/yukidama/external/tmp',
            '--setenv=PYTHONDONTWRITEBYTECODE=1',
            '--setenv=VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator', *map(str, argv)]
        save(unit+'-command.json', command)
        subprocess.run(command, check=True, timeout=30)
        owner = state(unit)
        save(unit+'-owner.json', owner)
        deadline = time.monotonic()+limit+60
        while True:
            actual = state(unit)
            assert actual['InvocationID'] == owner['InvocationID']
            if actual['MainPID'] == '0' and actual['SubState'] in ('exited', 'failed'):
                result['owners'].append(dict(unit=unit, **actual))
                assert actual['Result'] == 'success' and actual['ExecMainStatus'] == '0', actual
                return
            assert time.monotonic() < deadline, ('observation expired; do not restart', unit, actual)
            time.sleep(3)

    try:
        for unit, invocation, native in (
            ('ventium-mc-pair-srt-pc-queue-oct12.service', '4e26dd83304c4d4f9ba05bbbc5cc361a', '1'),
            ('ventium-mc-pair-srt-export-queue-oct12.service', '2912edfb32ee4c69a7756d06c52d10d1', '1'),
            ('ventium-mc-pair-srt-same-input-oct12.service', '4faddb219f7c4b0f8bccf6a66b7a0836', '0')):
            actual = state(unit)
            assert actual['InvocationID'] == invocation and actual['MainPID'] == '0'
            assert actual['SubState'] in ('exited', 'failed') and actual['ExecMainStatus'] == native
            result['owners'].append(dict(unit=unit, **actual))
        failed = load(root/'pc-queue-r1/closed.json')
        assert not failed['passed'] and failed['pins_unchanged']
        assert [row['error'] for row in failed['errors']] == ["KeyError('passed')"]
        for name in ('pc-queue-r1', 'export-queue-r1', 'canonical-same-input'):
            assert all(sha(path) == digest for path, digest in load(root/name/'started.json')['pins'].items())
        check_replay(load(root/'canonical-same-input/closed.json'))
        assert not (root/'soc-r1/build-started.json').exists()
        launch('ventium-mc-pair-srt-soc-oct12.service', ['/usr/bin/python3', '-B',
            REPO/'fpga/build_mc_pair_srt_soc.py', 'build', '--out', root/'soc-r1'], 800)
        assert load(root/'soc-r1/build-closed.json')['passed']
        cm_unit = 'ventium-v-carry-cm10-mc-pair-srt-oct12.service'
        launch(cm_unit, ['/usr/bin/taskset', '-c', '11', '/usr/bin/python3', '-B',
            REPO/'fpga/run_v_carry_payload_coremark.py', '--soc', root/'soc-r1', '--unit', cm_unit], 1300)
        subprocess.run(['/usr/bin/python3', '-B', str(REPO/'fpga/audit_v_carry_payload_coremark.py'),
            '--soc', str(root/'soc-r1'), '--unit', cm_unit], check=True, timeout=90)
        assert load(root/'soc-r1/coremark/audit.json')['passed']
        launch('ventium-mc-pair-srt-freeze-oct12.service', ['/usr/bin/python3', '-B',
            REPO/'fpga/freeze_mc_pair_srt_rk_candidate.py', '--parent',
            scratch/'ventium-mc-read-commit.PNi1O0xm/fpga-r1', '--sim', root/'soc-r1',
            '--out', root/'fpga-r1'], 300)
        receipt = load(root/'fpga-r1/freeze-receipt.json')
        assert receipt['source_contract_passed'] and receipt['payloads'] == 190
        assert receipt['manifest_sha256'] == sha(root/'fpga-r1/input-manifest.json')
        launch('ventium-mc-pair-srt-lint-oct12.service', ['/usr/bin/python3', '-B',
            REPO/'fpga/lint_frozen_rk_core.py', '--source', root/'fpga-r1',
            '--out', root/'lint-r1', '--manifest-sha256', receipt['manifest_sha256']], 400)
        assert load(root/'lint-r1/closed.json')['passed']
        result['passed'] = True
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result['pins_unchanged'] = stable()
    result['passed'] &= result['pins_unchanged']
    save('closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
