"""Observe unchanged failed prefix-boundary BIOSes in free-running QEMU.

Diagnostic only: changing TCG block granularity is not a passing differential
gate. The original failure remains failed, and no guest/model/oracle is edited.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time
import traceback

REPO = Path(__file__).resolve().parents[2]
QEMU = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
CASES = ('k2-r0-o4093', 'k2-r1-o4093', 'k3-r0-o4094', 'k3-r1-o4094',
         'k3-r0-o4095', 'k3-r1-o4095')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value,stream,indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--original',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args = parser.parse_args()
    source, root = args.original.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.environ['INVOCATION_ID'] and os.sched_getaffinity(0) == set(range(12,16))
    assert shutil.disk_usage(scratch).free > 4*1024**3
    before = json.loads((source/'started.json').read_text())
    closed = json.loads((source/'closed.json').read_text())
    assert not closed['passed'] and len(closed['errors']) == 12 and closed['pins_unchanged']
    pins = dict(before['pins'])
    assert all(sha(p)==h for p,h in pins.items())
    assert str(QEMU) in pins and sha(QEMU) == pins[str(QEMU)]
    for case in CASES:
        assert json.loads((source/case/'free-qemu.exit.json').read_text()) == {'native_exit':135}
        for name in ('test.bin','test.elf','free-qemu.argv.json','free-qemu.exit.json'):
            path=source/case/name; pins[str(path)]=sha(path)
    for path in (Path(__file__),source/'started.json',source/'closed.json'):
        pins[str(path)]=sha(path)
    root.mkdir()
    save(root/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cases=CASES,
        diagnostic_only=True,unchanged_images=True,canonical_oracle_changed=False))
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(root),PYTHONDONTWRITEBYTECODE='1')

    def one(index_case):
        index,case=index_case
        work=root/case; work.mkdir()
        original=json.loads((source/case/'free-qemu.argv.json').read_text())
        assert original[:4] == ['timeout','--signal=TERM','--kill-after=3s','45s']
        command=original[4:]
        assert Path(command[0]).resolve(strict=True) == QEMU.resolve(strict=True)
        image = Path(command[command.index('-bios')+1]).resolve(strict=True)
        assert image == source/case/'test.bin', (image,source/case/'test.bin')
        assert not any(flag in command for flag in ('-s','-S','-gdb','-singlestep','-accel'))
        rows=[]
        for mode,flags in (
            ('ordinary',[]),
            ('logged',['-d','in_asm,cpu,exec,int','-D',str(work/'logged.cpu.log')]),
            ('one-insn',['-accel','tcg,one-insn-per-tb=on','-d','in_asm,cpu,exec,int',
                         '-D',str(work/'one-insn.cpu.log')])):
            argv=['taskset','-c',str(12+index%4),*command,*flags]
            start=time.monotonic(); observed=False
            with (work/(mode+'.stdout')).open('x') as out, (work/(mode+'.stderr')).open('x') as err:
                process=subprocess.Popen(argv,stdout=out,stderr=err,env=env,start_new_session=True)
                try:
                    while process.poll() is None:
                        assert time.monotonic()-start < 20
                        assert shutil.disk_usage(scratch).free > 4*1024**3
                        logs=list(work.glob('*.cpu.log'))
                        assert sum(p.stat().st_size for p in logs) < 16*1024**2
                        try:
                            if Path('/proc',str(process.pid),'exe').resolve(strict=True)==QEMU.resolve():
                                assert os.sched_getaffinity(process.pid)=={12+index%4}
                                observed=True
                        except (FileNotFoundError,ProcessLookupError): pass
                        time.sleep(.001)
                    code=process.wait()
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid,signal.SIGTERM)
                        try: process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid,signal.SIGKILL);process.wait()
                assert observed and code in (133,135) and not Path('/proc',str(process.pid)).exists()
            row=dict(mode=mode,argv=argv,native_exit=code,actual_wait=True,child_reaped=True,
                affinity_observed=observed,seconds=time.monotonic()-start)
            save(work/(mode+'.closed.json'),row);rows.append(row)
        assert rows[0]['native_exit']==rows[1]['native_exit']==135
        return dict(case=case,rows=rows,image_sha256=sha(source/case/'test.bin'))

    begin=time.monotonic();rows=[];errors=[]
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures=[(case,pool.submit(one,(index,case))) for index,case in enumerate(CASES)]
        for case,future in futures:
            try: rows.append(future.result())
            except Exception as error:
                errors.append(dict(case=case,error=repr(error),traceback=traceback.format_exc()))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(diagnostic_completed=not errors and stable and len(rows)==len(CASES),
        rows=rows,errors=errors,pins_unchanged=stable,seconds=time.monotonic()-begin,
        original_boundary_gate_passed=False,standard_suite=False,hardware_acceptance=False,
        gameplay_ipc=None,artifacts={str(p.relative_to(root)):sha(p) for p in root.rglob('*') if p.is_file()})
    save(root/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','artifacts')},indent=2),flush=True)
    print([(r['case'],[(x['mode'],x['native_exit']) for x in r['rows']]) for r in rows],flush=True)
    return int(not result['diagnostic_completed'])


if __name__=='__main__':
    raise SystemExit(main())
