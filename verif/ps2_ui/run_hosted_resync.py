"""Bounded Icarus matrix for the exact retained-AUX hosted-device contract.

No active FPGA/full-PC sources are edited; no heavy compiler or board access.
Parent failures are explicit red witnesses, never correctness passes.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve()
REPO = Path(__file__).resolve().parents[2]
SOURCE = ROOT/'ps2-loss-aux-transport-r1/source'
HASHES = {
    'candidate.v': '9c9d62149a25a5e3f97683ca269b77d01dcf4034517c02a225a5bce0bd2dc405',
    'parent.v': '2ee3b64fc24875b3aaca0e6296a2514161f19cef5e6f79aa90923ca06f1846da',
    'simple_fifo.v': 'aff3ebc275191351eb582f2624cb056712d392331a951f1ed778360ca81f3bf4',
    'ven_ps2_device.sv': '8db5ceb38d329590e293e49ef67e4f347fe93fde5877d233f877b661de7fde48',
}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def cases(smoke=False):
    result = [('candidate', h, a, m, r, p) for h, a, m, r, p in
              itertools.product((3125000, 40000000), (0, 1), (0, 1), (0, 1),
                                (0,) if smoke else range(9))]
    return result + [('parent', h, a, m, r, 0) for h, a, m, r in
                     itertools.product((3125000, 40000000), (0, 1), (0, 1), (0, 1))]


def grade(case, code, text):
    label, hz, ack, mouse, reset, point = case
    rows = re.findall(r'HOSTED-RESYNC-OK hz=(\d+) mouse=(\d+) reset=(\d+) '
                      r'point=(\d+) aborts=(\d+) completed=(\d+) edges=(\d+)', text)
    if label == 'parent':
        return code == 1 and not rows and 'RESYNC-INHIBIT-MISSING' in text
    expected = (hz, mouse, reset, point, int(point < 8), 1+int(point == 8))
    # Edge count additionally checked natively at the precise interruption.
    return (code == 0 and len(rows) == 1 and tuple(map(int, rows[0][:6])) == expected
            and int(rows[0][6]) >= 12 and 'FATAL' not in text)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--smoke', action='store_true')
    args = ap.parse_args(); out = args.out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    assert ROOT.stat().st_dev != REPO.stat().st_dev
    assert out.parent.resolve(strict=True) == ROOT and not out.exists()
    assert sorted(os.sched_getaffinity(0)) == [12, 13]
    assert shutil.disk_usage(ROOT).free > 4*1024**3
    cg = Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0 < int((cg/'memory.max').read_text()) <= 512*1024**2
    assert (cg/'memory.swap.max').read_text().strip() == '0'
    assert 0 < int((cg/'pids.max').read_text()) <= 32
    assert os.environ.get('INVOCATION_ID')
    files = {name: SOURCE/name for name in HASHES}
    for name, path in files.items(): assert sha(path) == HASHES[name], name
    files['tb_hosted_resync.sv'] = REPO/'verif/ps2_ui/tb_hosted_resync.sv'
    pins = {str(p): sha(p) for p in [*files.values(), Path(__file__).resolve()]}
    out.mkdir(); src = out/'source'; src.mkdir()
    for name, path in files.items():
        shutil.copyfile(path, src/name)
        assert sha(src/name) == pins[str(path)]
        pins[str(src/name)] = sha(src/name)
    tools = {n: str(Path(shutil.which(n)).resolve(strict=True)) for n in ('iverilog', 'vvp')}
    pins.update({p: sha(p) for p in tools.values()})
    selected = cases(args.smoke)

    def save(name, obj):
        with (out/name).open('x') as stream: json.dump(obj, stream, indent=2)

    save('started.json', dict(invocation=os.environ['INVOCATION_ID'], pins=pins,
        affinity=[12, 13], cases=selected, smoke=args.smoke,
        contract='actual hosted RTL tx_aborted, not universal keyboard retry',
        physical_fpga=False, standard_suite=False, gameplay_ipc=None))
    start=time.monotonic(); builds=[]; rows=[]; errors=[]

    def execute(case):
        label,hz,ack,mouse,reset,point=case
        assert time.monotonic()-start < 500 and shutil.disk_usage(ROOT).free > 4*1024**3
        name=f'{label}-{hz}-a{ack}-m{mouse}-r{reset}-p{point}'
        cmd=[tools['vvp'], str(out/f'{label}-{hz}-a{ack}.vvp'),
             f'+mouse={mouse}', f'+reset={reset}', f'+point={point}']
        log=out/(name+'.log'); begin=time.monotonic()
        with log.open('x') as stream:
            child=subprocess.Popen(cmd, stdout=stream, stderr=subprocess.STDOUT)
            affinity=sorted(os.sched_getaffinity(child.pid))
            try:
                assert affinity == [12, 13]
                code=child.wait(timeout=30)
            except BaseException:
                child.kill(); child.wait(); raise
        good=grade(case,code,log.read_text())
        row=dict(case=case, command=cmd, native_pid=child.pid, native_exit=code,
                 waited=True, passed=good, correctness=label=='candidate' and good,
                 expected_red_witness=label=='parent' and good, affinity=affinity,
                 seconds=time.monotonic()-begin, log=str(log), log_sha256=sha(log))
        print(json.dumps({k: row[k] for k in ('case','native_exit','passed')}),flush=True)
        return row

    try:
        for label,hz,ack in itertools.product(('parent','candidate'),(3125000,40000000),(0,1)):
            name=f'{label}-{hz}-a{ack}'
            cmd=[tools['iverilog'],'-g2012','-Wall','-s','tb_hosted_resync',
                 '-Ptb_hosted_resync.HZ='+str(hz),'-DVEN_KBC_FAST',
                 *(['-DVEN_KBD_AUTOACK'] if ack else []),'-o',str(out/(name+'.vvp')),
                 *[str(src/n) for n in (label+'.v','simple_fifo.v','ven_ps2_device.sv','tb_hosted_resync.sv')]]
            with (out/(name+'-compile.log')).open('x') as stream:
                proc=subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT,timeout=30)
            builds.append(dict(command=cmd,native_exit=proc.returncode))
            assert proc.returncode == 0, name
        with ThreadPoolExecutor(max_workers=2) as pool:
            for row in pool.map(execute,selected):
                rows.append(row)
                if not row['passed']: errors.append(row['case'])
    except Exception as exc: errors.append(repr(exc))
    events={k:int(v) for k,v in (line.split() for line in (cg/'memory.events').read_text().splitlines())}
    stable=all(sha(p)==h for p,h in pins.items())
    good=not errors and stable and len(rows)==len(selected) and not any(
        events[k] for k in ('oom','oom_kill','oom_group_kill'))
    result=dict(passed=good, errors=errors, rows=rows, builds=builds,
        pins_unchanged=stable, memory_events=events, memory_peak=int((cg/'memory.peak').read_text()),
        seconds=time.monotonic()-start, smoke=args.smoke,
        physical_fpga=False, standard_suite=False, universal_keyboard_contract=False, gameplay_ipc=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','builds')}),flush=True)
    return 0 if good else 1


if __name__ == '__main__': raise SystemExit(main())
