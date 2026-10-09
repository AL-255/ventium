#!/usr/bin/env python3
"""Pin-only HALT/resume of pending/started REP reads using a frozen RTL archive.

Debug-active cases are boundary diagnostics, not performance or suite acceptance.
No generated RTL object is rebuilt or modified. Inactive-probe traces must be
byte-identical to the original model in both modes; active functional traces
must retain all original architectural records and a full pinned-QEMU match.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import traceback

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'verif/diff'))
import tracefmt


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('model-root', 'matrix', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    parent = args.model_root.resolve(strict=True)
    obj = parent / 'obj_board'
    original_receipt = json.loads((parent / 'build-closed.json').read_text())
    assert original_receipt['passed'] and original_receipt['inputs_unchanged']
    assert sha(obj / 'tb_ventium') == original_receipt['binary_sha256']
    prior = json.loads((parent / 'build-started.json').read_text())
    assert all(sha(p) == h for p, h in prior['pins'].items())
    host_paths = [Path(p) for p in prior['pins'] if p.endswith('.cpp') and Path(p).parent == parent]
    assert len(host_paths) == 1
    oldhost = host_paths[0]
    original = oldhost.read_text()
    hooks = {
        '#include "irq_inject_probe.h"': '#include "irq_inject_probe.h"\n#include "rep_debug_probe.h"',
        '    IrqInjectProbe irq_inject_probe;': '    IrqInjectProbe irq_inject_probe;\n    RepDebugProbe rep_debug_probe;',
        '        irq_inject_probe.pre_edge(*top, cycles + 1, 0);':
            '        irq_inject_probe.pre_edge(*top, cycles + 1, 0);\n        rep_debug_probe.pre_edge(*top);',
        '        irq_inject_probe.post_edge(*top, 0);':
            '        irq_inject_probe.post_edge(*top, 0);\n        rep_debug_probe.post_edge(*top, mem, cycles + 1);',
        '    irq_inject_probe.finish();': '    rep_debug_probe.finish();\n    irq_inject_probe.finish();',
    }
    for old, new in hooks.items():
        assert original.count(old) == 1
        original = original.replace(old, new)
    host = args.out / ('tb_rep_debug_' + args.out.name.replace('-', '_') + '.cpp')
    with host.open('x') as stream:
        stream.write(original)
    compile_cmd = shlex.split(next(line for line in (parent / 'build.log').read_text().splitlines()
                                  if ' -c -o ' + oldhost.stem + '.o ' in line))
    if compile_cmd[0] == 'ccache':
        compile_cmd.pop(0)
    compile_cmd[compile_cmd.index('-I.')] = '-I' + str(obj)
    compile_cmd.insert(1, '-I' + str(REPO / 'verif/rep_sfetch'))
    compile_cmd[compile_cmd.index('-o') + 1] = str(args.out / 'probe.o')
    compile_cmd[-1] = str(host)
    objects = [obj / (name + '.o') for name in ('dpi_retire', 'memmodel', 'quake_image', 'syscall_emu',
                                              'win95_cosim', 'verilated', 'verilated_dpi', 'verilated_threads')]
    archive = obj / 'Vventium_top__ALL.a'
    pins = dict(prior['pins'])
    assert json.loads((args.matrix / 'result.json').read_text())['passed']
    for path in args.matrix.rglob('*'):
        if path.is_file() and (path.suffix in ('.bin', '.vtrace') or path.name.endswith('.command.json')):
            pins[str(path)] = sha(path)
    for path in [Path(__file__), REPO / 'verif/rep_sfetch/rep_debug_probe.h', host, archive,
                 REPO / 'verif/diff/compare.py', REPO / 'verif/diff/tracefmt.py',
                 args.matrix / 'result.json', obj / 'tb_ventium', *obj.glob('*.h'), *objects]:
        pins[str(path)] = sha(path)
    save(args.out / 'inputs.json', pins)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(TMPDIR=str(args.out), CCACHE_DISABLE='1', PYTHONDONTWRITEBYTECODE='1')

    def run(argv, leaf, name, expected=0, extra=None):
        command = ['timeout', '--signal=TERM', '--kill-after=3s', '90s', *map(str, argv)]
        save(leaf / (name + '.command.json'), dict(argv=command, environment=extra))
        with (leaf / (name + '.stdout')).open('x') as out, (leaf / (name + '.stderr')).open('x') as err:
            rc = subprocess.run(command, cwd=args.out, env=dict(env, **(extra or {})),
                                stdout=out, stderr=err).returncode
        save(leaf / (name + '.exit.json'), dict(exit=rc))
        assert rc == expected, (name, rc, expected)

    result = dict(passed=False, cases=[], errors=[], rtl_rebuilt=False, gameplay_ipc=None,
                  diagnostic_only=True, standard_suite=False, started=time.time())
    try:
        run(compile_cmd, args.out, 'compile')
        dep = (args.out / 'probe.d').read_text().replace('\\\n', ' ')
        assert str(obj / 'Vventium_top___024root.h') in dep
        binary = args.out / 'tb_probe'
        run(['g++', *objects, args.out / 'probe.o', archive, '-pthread', '-lpthread', '-latomic',
             '-o', binary], args.out, 'link')
        result['probe_binary_sha256'] = sha(binary)

        def measure(job):
            offset, latency, phase = job
            fixture = args.matrix / f'basic-o{offset}'
            leaf = args.out / f'o{offset}-l{latency}-{phase}'
            leaf.mkdir()
            extra = dict(AXI_RLAT=str(latency), AXI_WLAT=str(latency))
            if phase != 'off':
                extra.update(VEN_TEST_REP_DEBUG_PC=hex(0x8000+offset), VEN_TEST_REP_DEBUG_PHASE=phase)
            for mode in ('cycle-func', 'cycle'):
                old = fixture / f'candidate-l{latency}-{mode}'
                command = json.loads(old.with_suffix('.command.json').read_text())
                # Existing matrix stores the complete timeout + native argv.
                command = command[4:]
                assert command[0] == str(obj / 'tb_ventium') or Path(command[0]).resolve() == obj / 'tb_ventium'
                command[0] = str(binary)
                trace = leaf / (mode + '.vtrace')
                command[command.index('--out')+1] = str(trace)
                run(command, leaf, mode, 133, extra)
                stdout = (leaf / (mode + '.stdout')).read_text()
                stderr = (leaf / (mode + '.stderr')).read_text()
                assert '%Error' not in stdout + stderr and '%Fatal' not in stdout + stderr
                if phase == 'off':
                    assert sha(trace) == sha(old.with_suffix('.vtrace'))
                    assert '[REP-DEBUG]' not in stderr
                else:
                    assert stderr.count('[REP-DEBUG] PASS ') == 1
                    assert stderr.count('stable_edges=1024 committed=') == 1
                    cancels = [line for line in stdout.splitlines() if '[MOVSSTREAM] CANCEL ' in line]
                    if phase == 'pending':
                        assert len(cancels) == 1 and 'dbg=1 ' in cancels[0]
                    else:
                        assert not cancels
                    if mode == 'cycle-func':
                        run([sys.executable, REPO / 'verif/diff/compare.py', '--mode', 'func',
                             old.with_suffix('.vtrace'), trace], leaf, 'parent-diff')
                        run([sys.executable, REPO / 'verif/diff/compare.py', '--mode', 'func',
                             fixture / 'golden.vtrace', trace], leaf, 'qemu-diff')
                rows = tracefmt.read_trace(str(trace)).records
                assert [r['n'] for r in rows] == list(range(len(rows)))
                if mode == 'cycle':
                    assert any(r.get('pipe') == 'V' and r.get('paired') for r in rows)
            return dict(offset=offset, latency=latency, phase=phase, passed=True)

        jobs = [(o, l, p) for o in (0,17,31) for l in (0,7) for p in ('off','pending','started')]
        with concurrent.futures.ThreadPoolExecutor(max_workers=18) as pool:
            pending = {pool.submit(measure, job): job for job in jobs}
            for future in concurrent.futures.as_completed(pending):
                try:
                    result['cases'].append(future.result())
                except Exception as exc:
                    result['errors'].append(dict(case=pending[future], error=repr(exc), traceback=traceback.format_exc()))
        assert len(result['cases']) == len(jobs) and not result['errors']
        result['passed'] = True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc), traceback=traceback.format_exc()))
    finally:
        result['inputs_unchanged'] = all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        result['finished'] = time.time()
        save(args.out / 'closed.json', result)
    print(json.dumps(result, indent=2), flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
