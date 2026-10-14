"""Bounded actual-iobus PS/2 AUX-origin microgate (not Windows acceptance).

Run through tools/build_scope.sh; its shared lock serializes this small build
behind Vivado. No resource-policy bypass is permitted for this leaf test.
"""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time

import prepare_aux_status as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
REL = '3rd-party/ao486_MiSTer/rtl/'
INPUTS = {
    REL + 'soc/ps2.v': recipe.PARENT,
    REL + 'soc/iobus.v': '59a36814438e730af6bb036e1906278a04bcfea7c4aaea4f4878ed341f82e92d',
    REL + 'common/simple_fifo.v': 'aff3ebc275191351eb582f2624cb056712d392331a951f1ed778360ca81f3bf4',
}
PROFILES = ((), ('VEN_KBC_FAST',), ('VEN_KBD_AUTOACK',),
            ('VEN_KBC_FAST', 'VEN_KBD_AUTOACK'))


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def matrix():
    for scenario, sources, translation, irq, wait in itertools.product(
            range(6), range(4), range(2), range(2), (0, 1, 7, 31)):
        yield scenario, sources, 64, wait, translation, irq
    for translation, irq, wait in itertools.product(range(2), range(2), (0, 1, 7, 31)):
        yield 6, 0, 64, wait, translation, irq
    # Actual wire edges at the prior physical-rate controls, plus the shortest
    # debounce-qualified cell. No controller-output shortcut for these cases.
    for scenario, half, translation, irq, wait in itertools.product(
            (2, 6), (32, 1875, 2917), range(2), range(2), (0, 1, 7, 31)):
        yield scenario, 0, half, wait, translation, irq


def after_owner(unit, invocation, root):
    """Wait for this exact owner; a polling error never implies termination."""
    if not unit.startswith('ventium-') or not unit.endswith('.service'):
        raise ValueError('not a Ventium service')
    if len(invocation) != 32 or any(c not in '0123456789abcdef' for c in invocation):
        raise ValueError('not an invocation ID')
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    watched = [Path(__file__), Path(recipe.__file__), HERE/'tb_ps2_aux_status.sv',
               HERE/'test_aux_status.py', REPO/'tools/build_scope.sh',
               REPO/'tools/verilator_serial.sh', *[REPO/p for p in INPUTS]]
    pins = {str(p): sha(p) for p in watched}
    begin = time.monotonic()
    seen_live = False
    while time.monotonic() - begin < 2700:
        query = subprocess.run(['systemctl', '--user', 'show', unit,
            '-p', 'ActiveState', '-p', 'SubState', '-p', 'MainPID', '-p', 'InvocationID',
            '-p', 'Result', '-p', 'ExecMainStatus'], capture_output=True, text=True, timeout=10)
        if query.returncode != 0:
            time.sleep(5)
            continue
        state = dict(line.split('=', 1) for line in query.stdout.splitlines() if '=' in line)
        if state.get('InvocationID') != invocation:
            raise RuntimeError('prerequisite identity changed or disappeared; refusing launch')
        if state.get('ActiveState') == 'active' and int(state.get('MainPID', 0)) > 0:
            seen_live = True
        elif (seen_live and state.get('MainPID') == '0' and
              state.get('ActiveState') in ('inactive', 'failed', 'active') and
              state.get('SubState') in ('dead', 'failed', 'exited')):
            assert all(sha(p) == digest for p, digest in pins.items())
            with root.with_suffix('.prerequisite.json').open('x') as stream:
                json.dump(dict(unit=unit, state=state, seen_live=True,
                               seconds=time.monotonic()-begin, pins=pins), stream, indent=2)
            # Its result is recorded, not converted to a timing pass. The PS/2
            # leaf is useful even if unrelated synthesis failed. Native guard
            # still obtains the real fixed heavy-build lock and capped scope.
            command = [str(REPO/'tools/build_scope.sh'), '--', 'taskset', '-c', '13',
                       'python3', '-B', str(Path(__file__).resolve()), '--out', str(root)]
            os.execvpe(command[0], command, os.environ.copy())
        time.sleep(5)
    raise TimeoutError('prerequisite observation budget ended; no build launched')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--after-unit')
    ap.add_argument('--after-invocation')
    args = ap.parse_args()
    if not __debug__:
        raise RuntimeError('assertions must stay enabled')
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    if args.after_unit or args.after_invocation:
        if not args.after_unit or not args.after_invocation:
            raise ValueError('both prerequisite identity fields are required')
        after_owner(args.after_unit, args.after_invocation, root)
    assert root.is_relative_to(scratch) and not root.exists()
    assert scratch.stat().st_dev != REPO.stat().st_dev
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.sched_getaffinity(0) == {13}
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'default'
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    unit = os.environ['VENTIUM_BUILD_SCOPE_UNIT'] + '.scope'
    subprocess.run(['systemctl', '--user', 'set-property', '--runtime', unit,
                    'MemoryMax=2G', 'MemorySwapMax=0', 'TasksMax=64'], check=True, timeout=10)
    cg = Path('/sys/fs/cgroup' + Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert (cg/'memory.max').read_text().strip() == str(2*1024**3)
    assert (cg/'memory.swap.max').read_text().strip() == '0'
    subprocess.run([REPO/'tools/verilator_serial.sh', '--version'], check=True, timeout=10)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    start = time.monotonic()

    def guard():
        if time.monotonic() - start > 590:
            raise RuntimeError('leaf total time budget reached')
        if shutil.disk_usage(scratch).free < 4*1024**3:
            raise RuntimeError('external 4 GiB disk floor reached')
        mem = dict((line.split(':')[0], int(line.split()[1])*1024)
                   for line in Path('/proc/meminfo').read_text().splitlines()
                   if line.startswith('MemAvailable:'))
        if mem['MemAvailable'] < 2*1024**3:
            raise RuntimeError('2 GiB host reserve reached')

    guard()
    for path, expected in INPUTS.items():
        assert sha(REPO/path) == expected, path
    pinned = list(REPO/path for path in INPUTS) + [Path(__file__), Path(recipe.__file__),
        HERE/'tb_ps2_aux_status.sv', HERE/'test_aux_status.py',
        REPO/'tools/build_scope.sh', REPO/'tools/verilator_serial.sh',
        Path(os.environ['VENTIUM_VERILATOR_BIN'])]
    pins = {str(path): sha(path) for path in pinned}
    root.mkdir()

    def save(path, data):
        with path.open('x') as stream:
            stream.write(data)

    def save_json(name, data):
        save(root/name, json.dumps(data, indent=2) + '\n')

    def generated(name, contents):
        path = root/name
        save(path, contents)
        pins[str(path)] = sha(path)
        return path

    original = (REPO/(REL+'soc/ps2.v')).read_text()
    # The deployable one-line derivative is retained separately from the four
    # test-only module renamings. Never overwrite the live submodule or freeze.
    candidate = generated('ps2.v', recipe.transform(original))
    sources = [generated('ps2_aux_'+name+'.sv', recipe.variant(original, name))
               for name in ('parent', 'fixed', 'zero', 'one')]
    for relpath in ('soc/iobus.v', 'common/simple_fifo.v'):
        src = REPO/(REL+relpath)
        # Copy bytes: iobus.v uses CRLF in this reviewed source revision.
        dest = root/src.name
        with dest.open('xb') as stream:
            stream.write(src.read_bytes())
        assert sha(dest) == sha(src)
        pins[str(dest)] = sha(dest)
        sources.append(dest)
    sources.append(generated('tb_ps2_aux_status.sv', (HERE/'tb_ps2_aux_status.sv').read_text()))
    save_json('started.json', dict(pins=pins, candidate_sha256=sha(candidate),
              profiles=PROFILES, invocation=os.environ.get('INVOCATION_ID'),
              scope=unit, affinity=sorted(os.sched_getaffinity(0))))
    result = dict(passed=False, errors=[], rows=[], builds=[], input_pins=pins,
                  full_pc=False, standard_suite=False, fpga_acceptance=False,
                  gameplay_ipc=None, source_delta='8042 status bit 5 only')

    def native(folder, model, number, variant, case, expected):
        guard()
        fields = ('scenario', 'sources', 'half', 'wait', 'translate', 'interrupts')
        command = [str(model), '+variant='+str(variant)] + [
            '+'+key+'='+str(value) for key, value in zip(fields, case)]
        logpath = folder/f'case-{number:04d}.log'
        with logpath.open('x') as log:
            child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            affinity = sorted(os.sched_getaffinity(child.pid))
            assert affinity == [13]
            try:
                code = child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
                raise
        log = logpath.read_text()
        row = dict(command=command, exit=code, expected=expected, affinity=affinity,
                   log=str(logpath), log_sha256=sha(logpath))
        result['rows'].append(row)
        if expected == 'pass':
            assert code == 0 and 'PS2-AUX-OK ' in log, row
        else:
            # Retain a real failed old/mutant native process. It is a bug
            # witness, never a passing controller or standard-suite result.
            assert code in (-6, 1, 134) and 'PS2-AUX-ORIGIN-MISMATCH' in log, row
            assert 'PS2-AUX-OK ' not in log, row

    try:
        for index, defines in enumerate(PROFILES):
            guard()
            folder = root/f'profile-{index}'
            folder.mkdir()
            command = [str(REPO/'tools/verilator_serial.sh'), '--binary', '--timing',
                '--assert', '-sv', '-j', '1', '--threads', '1', '-Wall', '-Wno-UNUSED',
                '-Wno-fatal', *['-Werror-'+warning for warning in
                ('IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                *['+define+'+d for d in defines], '--top-module', 'tb_ps2_aux_status',
                '--Mdir', str(folder/'obj'), '-o', 'test', *map(str, sources)]
            with (folder/'build.log').open('x') as log:
                proc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                      pass_fds=(9,), timeout=120)
            result['builds'].append(dict(command=command, exit=proc.returncode,
                                        log_sha256=sha(folder/'build.log')))
            assert proc.returncode == 0, folder/'build.log'
            model = folder/'obj/test'
            model_hash = sha(model)
            number = 0
            for case in matrix():
                for variant in (0, 1):
                    expected = 'parent_bug' if variant == 0 and case[0] in (2, 4, 5) else 'pass'
                    native(folder, model, number, variant, case, expected)
                    number += 1
            for variant, scenario in ((2, 1), (3, 0)):
                for input_sources in (0, 3):
                    native(folder, model, number, variant,
                           (scenario, input_sources, 64, 31, 1, 1), 'constant_aux_mutant')
                    number += 1
            assert sha(model) == model_hash
            result['builds'][-1]['model_sha256'] = model_hash
            print(f'PS2-AUX-PROFILE-CLOSED profile={index} executions={number}', flush=True)
        result['passed'] = True
    except Exception as error:
        result['errors'].append(repr(error))
    result['pins_unchanged'] = all(sha(path) == expected for path, expected in pins.items())
    result['memory_events'] = (cg/'memory.events').read_text()
    result['memory_peak'] = int((cg/'memory.peak').read_text())
    result['passed'] &= result['pins_unchanged'] and all(
        int(line.split()[1]) == 0 for line in result['memory_events'].splitlines()
        if line.split()[0] in ('oom', 'oom_kill', 'oom_group_kill'))
    result['seconds'] = time.monotonic() - start
    result['counts'] = {key: sum(row['expected'] == key for row in result['rows'])
                        for key in ('pass', 'parent_bug', 'constant_aux_mutant')}
    save_json('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows', 'builds', 'input_pins')}, indent=2))
    return int(not result['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
