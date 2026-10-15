"""Run unchanged cold memory corpora concurrently on the payload-mux model.

No stimulus or grading edits. Record native reaping and observed actual child
affinity; the retained runners compare complete QEMU state and A/B clocks.
"""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
ROOT = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve(strict=True)
MODELS = dict(control='e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6',
              candidate='7c88579767354f269055420cafe3acca089acda87e5ac174b633b3e7905dcdb5')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def descendants(pid):
    found, pending = [], [pid]
    while pending:
        parent = pending.pop()
        for task in Path(f'/proc/{parent}/task').glob('*'):
            try:
                children = [int(s) for s in (task/'children').read_text().split()]
            except (FileNotFoundError, ProcessLookupError):
                continue
            for child in children:
                if child not in found:
                    found.append(child)
                    pending.append(child)
    return found


def main():
    scratch = ROOT.parent
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3
    out = ROOT/'backing-payload-mux-system-r1'
    out.mkdir()
    models = {k:ROOT/(n+'-core-r1/obj/tb_ventium') for k,n in (
        ('control','prefix-payload'), ('candidate','backing-payload-mux'))}
    assert all(sha(p) == MODELS[k] for k,p in models.items())
    drivers = dict(load=HERE/'run_l1_capture_cut_system.py',
                   store=HERE/'run_l1_write_kind_system.py',
                   coldalias=HERE/'run_current_u_pair_cold_alias.py')
    pins = {str(p):sha(p) for p in (*models.values(), *drivers.values(), Path(__file__))}
    save(out/'started.json', dict(pins=pins, models=MODELS, invocation=os.environ['INVOCATION_ID']))
    start = time.monotonic()

    def run(item):
        index, (label, driver) = item
        cpus = set(range(4+index*4, 8+index*4))
        command = ['taskset','-c',','.join(map(str,sorted(cpus))),
            'timeout','--signal=TERM','--kill-after=5s','180s',
            '/usr/bin/python3','-B',str(driver),'--out',str(out/label),
            '--control',str(models['control']),'--candidate',str(models['candidate'])]
        save(out/(label+'.command.json'), command)
        observed = {}
        with (out/(label+'.log')).open('x') as log:
            child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            while child.poll() is None:
                for pid in descendants(child.pid):
                    try:
                        exe = Path(f'/proc/{pid}/exe').resolve(strict=True).name
                        affinity = sorted(os.sched_getaffinity(pid))
                    except (FileNotFoundError, ProcessLookupError):
                        continue
                    if exe in ('tb_ventium', 'qemu-system-i386'):
                        observed[str(pid)] = dict(executable=exe, affinity=affinity)
                time.sleep(0.02)
            rc = child.wait()
        checked = json.loads((out/label/'closed.json').read_text())
        affinity_ok = {r['executable'] for r in observed.values()} == {'tb_ventium','qemu-system-i386'}
        affinity_ok &= all(set(r['affinity']) == cpus for r in observed.values())
        passed = rc == 0 and checked['passed'] and checked['pins_unchanged'] and affinity_ok
        row = dict(label=label, passed=passed, native_exit=rc, actual_wait=True, reaped=True,
                   observed_affinity=observed, affinity_verified=affinity_ok,
                   closure_sha256=sha(out/label/'closed.json'), log_sha256=sha(out/(label+'.log')))
        save(out/(label+'.receipt.json'), row)
        return row

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        rows = list(pool.map(run, enumerate(drivers.items())))
    unchanged = all(sha(p) == h for p,h in pins.items())
    result = dict(passed=all(r['passed'] for r in rows) and unchanged, rows=rows,
                  pins_unchanged=unchanged, seconds=time.monotonic()-start,
                  canonical_gate_passed=False, standard_suite=False,
                  hardware_acceptance=False, gameplay_ipc=None)
    save(out/'closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k != 'rows'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
