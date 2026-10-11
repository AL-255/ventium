#!/usr/bin/env python3
"""Run unchanged FP fault fixtures on both read-ACK models; compare full UV traces.

Run inside tools/build_scope.sh. The original gate has a fixed QEMU port, so
cases and models are deliberately serialized. Its functional-mode control is
diagnostic only; complete cycle-functional comparison is separately required.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'verif/diff'))
import tracefmt


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def cases():
    result = []
    for kind in range(3):
        for nm, pending in ((0, 0), (4, 0), (8, 0), (0, 1)):
            result.append(dict(kind=kind, nm=nm, pending=pending, segment=0))
    for segment in (1, 2):
        for pending in (0, 1):
            result.append(dict(kind=0, nm=0, pending=pending, segment=segment))
    return result


def environment(case, model, out):
    return dict(TB_BIN=str(model), OUTDIR=str(out), FP_MEM_ADMIT='1',
                FP_LOAD_COMMAND='1', FP_LOAD_KIND=str(case['kind']),
                FP_NM_PRIORITY=str(case['nm']), FP_PENDING=str(case['pending']),
                FP_SEG_RELOC=str(case['segment']))


def compare_command(golden, actual):
    return [sys.executable, '-B', str(REPO / 'verif/diff/compare.py'),
            '--mode', 'func', '--all', str(golden), str(actual)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ('parent', 'candidate', 'out'):
        parser.add_argument('--' + flag, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    subprocess.run([str(REPO / 'tools/build_scope.sh'), '--is-active'],
                   pass_fds=(9,), check=True)
    roots = dict(control=args.parent.resolve(strict=True),
                 candidate=args.candidate.resolve(strict=True))
    models, pins, profiles = {}, {}, []
    for name, root in roots.items():
        closed = json.loads((root / 'build-closed.json').read_text())
        started = json.loads((root / 'build-started.json').read_text())
        assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
        model = root / 'obj/tb_ventium'
        assert sha(model) == closed['binary_sha256']
        models[name] = model
        pins.update(started['pins'])
        stamp = root / 'obj/Vventium_top__verFiles.dat'
        command = next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
        defines = set(re.findall(r'\+define\+(\w+)', command))
        assert {'VEN_L1_AXI', 'VEN_FP_LOAD_EARLY_CMD', 'VEN_FP_MEM_ADMIT',
                'VEN_FE_PIPE', 'VEN_SYS_FASTPATH_RELOC'} <= defines
        assert not {'SYNTHESIS', 'VTM_NO_DPI'} & defines and ' --assert ' in command
        profiles.append(defines)
        for path in (model, stamp, root / 'build-started.json', root / 'build-closed.json'):
            pins[str(path)] = sha(path)
    assert profiles[0] == profiles[1]
    gate = REPO / 'verif/issue_uv/run-fp-memory-fault-gate.sh'
    for path in (Path(__file__), gate, REPO / 'verif/diff/compare.py',
                 REPO / 'verif/diff/tracefmt.py', REPO / 'verif/qemu-trace/gen_trace.py',
                 REPO / 'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386',
                 REPO / 'verif/sys/tests/prepsfetch/prepsfetch.S',
                 REPO / 'verif/sys/tests/prepsfetch/prepsfetch.ld'):
        pins[str(path)] = sha(path)
    assert all(sha(p) == digest for p, digest in pins.items())
    out.mkdir()

    def save(path, value):
        with path.open('x') as stream:
            json.dump(value, stream, indent=2)

    save(out / 'started.json', dict(pins=pins, cases=cases(),
         models={k: str(v) for k, v in models.items()},
         invocation=os.environ.get('INVOCATION_ID'), affinity=sorted(os.sched_getaffinity(0)),
         gameplay_ipc=None, standard_suite=False))
    result = dict(passed=False, errors=[], measurements=[], gameplay_ipc=None,
                  standard_suite=False, physical_board=False)
    clean_env = {k: v for k, v in os.environ.items()
                 if not k.startswith(('VEN_', 'VTM_', 'TB_', 'QEMU_', 'AXI_', 'FP_'))}

    def native(stem, command, env, seconds):
        save(stem.with_suffix('.command.json'), dict(command=command, fixture_env=env))
        begin = time.monotonic()
        timed_out = False
        with stem.with_suffix('.log').open('x') as stream:
            child = subprocess.Popen(command, env=dict(clean_env, **env), stdout=stream,
                                     stderr=subprocess.STDOUT, pass_fds=(9,), start_new_session=True)
            affinity = sorted(os.sched_getaffinity(child.pid))
            assert affinity == sorted(os.sched_getaffinity(0))
            try:
                status = child.wait(timeout=seconds)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    status = child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    status = child.wait(timeout=5)
                # A shell can exit on TERM before its nested QEMU exits. Reap
                # only this newly created process group, never another run.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        receipt = dict(native_exit=status, timed_out=timed_out,
                       seconds=time.monotonic()-begin, affinity=affinity)
        save(stem.with_suffix('.exit.json'), receipt)
        if status != 0 or timed_out:
            result['errors'].append(dict(stem=str(stem), **receipt))
        return receipt

    try:
        for index, case in enumerate(cases()):
            folder = out / ('case-%02d' % index)
            folder.mkdir()
            records, images = {}, {}
            for name, model in models.items():
                leaf = folder / name
                entry = dict(case=case, model=name)
                entry['gate'] = native(folder / (name + '-gate'), ['bash', str(gate)],
                                       environment(case, model, leaf), 90)
                golden, actual = leaf / 'qemu.vtrace', leaf / 'cycle-func.vtrace'
                if golden.is_file() and actual.is_file():
                    entry['complete_uv_compare'] = native(folder / (name + '-full-uv'),
                        compare_command(golden, actual), {}, 30)
                    trace = tracefmt.read_trace(str(actual))
                    assert trace.sys and trace.x87 and 0 < len(trace.records) < 2500
                    records[name] = trace.records
                    images[name] = sha(leaf / 'image/test.bin')
                    entry['records'] = len(trace.records)
                else:
                    result['errors'].append(dict(case=case, model=name, error='missing full UV trace'))
                result['measurements'].append(entry)
            assert images.keys() == records.keys() == models.keys()
            assert images['control'] == images['candidate'], ('input mismatch', case)
            if records['control'] != records['candidate']:
                result['errors'].append(dict(case=case, error='complete same-input A/B trace differs'))
            print(json.dumps(dict(case=case, closed=True, errors=len(result['errors']))), flush=True)
        result['passed'] = not result['errors'] and len(result['measurements']) == 32
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result['pins_unchanged'] = all(sha(p) == digest for p, digest in pins.items())
        result['passed'] &= result['pins_unchanged']
        result['artifacts'] = {str(p.relative_to(out)): sha(p)
                               for p in out.rglob('*') if p.is_file()}
        save(out / 'closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
