"""Bounded native owner tests for the exact slow-fetch register experiment."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import prepare_sfetch_beat_stage as recipe

HERE = Path(__file__).resolve().parent
MODES = ('positive', 'bypass', 'lose-walk', 'raw-ack', 'reload', 'wrong-size')


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def fixture(mode):
    stage = recipe.STAGE
    edits = {
        'bypass': ('sfetch_beat_valid_q;', '(sfetch_beat_valid_q || sfetch_want_req);'),
        'lose-walk': ('!((state == S_WALK) && (walk_ret_state == S_FETCH))', "1'b1"),
        'raw-ack': ('fsm_case_enabled && mem_req && mem_ack', 'mem_ack'),
        'reload': ("sfetch_beat_valid_q <= 1'b0;\n      end else if", "sfetch_beat_valid_q <= sfetch_want_req;\n      end else if"),
        'wrong-size': ('sfetch_beat_size_q <= sfetch_want_size;', "sfetch_beat_size_q <= 3'd4;"),
    }
    if mode != 'positive':
        old, new = edits[mode]
        # For bypass, change the assignment, not the signal declaration.
        if mode == 'bypass':
            old, new = '                             '+old, '                             '+new
        stage = recipe.replace_once(stage, old, new)
    return recipe.replace_once((HERE/'tb_sfetch_beat_stage.sv').read_text(),
                               '  // EXTRACTED_STAGE', stage)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    source, out = a.source.resolve(strict=True), a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert out.is_relative_to(scratch) and not out.exists() and os.access(scratch, os.W_OK)
    assert scratch.stat().st_dev != HERE.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.environ['INVOCATION_ID'] and os.sched_getaffinity(0) == {12, 13}
    group = Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert int((group/'memory.max').read_text()) <= 512*1024**2
    assert (group/'memory.swap.max').read_text().strip() == '0'
    pins = {str(p.resolve()): sha(p) for p in
            (Path(__file__), Path(recipe.__file__), HERE/'tb_sfetch_beat_stage.sv',
             Path('/usr/bin/iverilog'), Path('/usr/bin/vvp'),
             *(source/n for n in recipe.PARENTS))}
    changed = {n: recipe.transform((source/n).read_text(), n) for n in recipe.PARENTS}
    out.mkdir()
    def save(name, data):
        with (out/name).open('x') as f:
            json.dump(data, f, indent=2)
    for name, text in changed.items():
        with (out/Path(name).name).open('x') as f:
            f.write(text)
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'], source=str(source)))
    start = time.monotonic()
    rows, errors = [], []
    try:
        for mode in MODES:
            sv, exe = out/(mode+'.sv'), out/(mode+'.vvp')
            with sv.open('x') as f:
                f.write(fixture(mode))
            command = ['/usr/bin/iverilog', '-g2012', '-s', 'tb', '-o', str(exe), str(sv)]
            with (out/(mode+'.build.log')).open('x') as f:
                built = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, timeout=30)
            assert built.returncode == 0, (mode, 'compile')
            with (out/(mode+'.log')).open('x') as f:
                child = subprocess.Popen(['/usr/bin/vvp', str(exe)], stdout=f, stderr=subprocess.STDOUT)
                affinity = sorted(os.sched_getaffinity(child.pid))
                assert affinity == [12, 13]
                try:
                    status = child.wait(timeout=30)
                except BaseException:
                    child.kill(); child.wait(); raise
            log = (out/(mode+'.log')).read_text()
            passed = (status == 0 and 'SFETCH-BEAT-OK checks=28672 beats=4096' in log) if mode == 'positive' else (
                status == 1 and 'SFETCH-BEAT-MISMATCH' in log)
            rows.append(dict(mode=mode, compile_exit=built.returncode, native_exit=status,
                             actual_wait=True, affinity=affinity, passed=passed, command=command))
            assert passed, (mode, log)
    except Exception as error:
        errors.append(repr(error))
    events = {k:int(v) for k,v in (s.split() for s in (group/'memory.events').read_text().splitlines())}
    stable = all(sha(p) == h for p,h in pins.items())
    result = dict(passed=not errors and stable and len(rows)==len(MODES) and
                  not any(events[k] for k in ('oom','oom_kill','oom_group_kill')),
                  rows=rows, errors=errors, pins_unchanged=stable, memory_events=events,
                  seconds=time.monotonic()-start, whole_core=False, hardware_acceptance=False,
                  artifacts={str(p):sha(p) for p in out.iterdir() if p.is_file()}, gameplay_ipc=None)
    save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
