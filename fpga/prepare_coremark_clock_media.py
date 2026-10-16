"""Build unchanged 2,000-iteration BIOS media and both native QEMU CRC oracles.

The 40 MHz port calibration remains explicit. Hardware sweep grading must use
measured TSC frequency for actual elapsed seconds, never the printed calibrated
seconds or QEMU timing. No FPGA, guest, voltage or clock access here.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[1]
PORT = REPO/'verif/bench/coremark_boot'
sys.path.insert(0,str(PORT))
import build as builder

ITERATIONS = 2000
TIMING_ERRORS = {
    'ERROR! Must execute for at least 10 secs for a valid result!',
    'ERROR! TSC interval exceeds 32-bit CoreMark ticks',
}


def grade_reference(text, seed, iterations=ITERATIONS):
    def one(pattern):
        matches = re.findall(pattern,text,re.M)
        if len(matches) != 1: raise ValueError(('missing/duplicate field',pattern,matches))
        return matches[0]
    if iterations not in (2000,4000) or one(r'^Iterations\s*:\s*(\d+)$') != str(iterations):
        raise ValueError('wrong iteration count')
    if one(r'^CoreMark Size\s*:\s*(\d+)$') != '666':
        raise ValueError('not the standard data set')
    fields = ('seedcrc','crclist','crcmatrix','crcstate','crcfinal')
    crcs = [one(r'^(?:\[0\])?'+field+r'\s*:\s*0x([0-9a-f]{4})$') for field in fields]
    if crcs[:4] != builder.CRCS[seed][:4]: raise ValueError('algorithm/seed CRC mismatch')
    if text.count('PORT-END\n') != 1: raise ValueError('not complete')
    errors = re.findall(r'^.*ERROR.*$',text,re.M)
    if any(line not in TIMING_ERRORS for line in errors):
        raise ValueError(('QEMU non-timing error',errors))
    if ('Correct operation validated.' not in text and
            'ERROR! Must execute for at least 10 secs for a valid result!' not in errors):
        raise ValueError('missing framework verdict')
    return dict(crcs=crcs,iterations=iterations,reference_only=True,
        timing_errors=errors,qemu_time_is_not_fpga_time=True,
        physical_board=False,standard_suite=False)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--iterations',type=int,choices=(2000,4000),default=ITERATIONS)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    out=args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert out.is_relative_to(scratch) and out!=scratch and not out.exists()
    assert os.sched_getaffinity(0)=={16,17} and os.environ['INVOCATION_ID']
    group=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((group/'memory.max').read_text())<=512*1024**2
    assert (group/'memory.swap.max').read_text().strip()=='0'
    out.mkdir()
    qemu=builder.REFS/'build/qemu/build-sys/qemu-system-i386'
    inputs=[Path(__file__),Path(builder.__file__),qemu,
            builder.REFS/'build/qemu/pc-bios/bios-256k.bin']
    pins={str(p.resolve()):builder.sha(p) for p in inputs}
    def save(name,value):
        with (out/name).open('x') as stream: json.dump(value,stream,indent=2)
    save('started.json',dict(invocation=os.environ['INVOCATION_ID'],pins=pins,
        iterations=args.iterations,affinity=sorted(os.sched_getaffinity(0))))
    start=time.monotonic();errors=[];rows=[]
    try:
        builder.command([sys.executable,'-B',PORT/'build.py','--out',out/'media',
            '--iterations',str(args.iterations)],out/'build.log',seconds=120)
        built=json.loads((out/'media/closed.json').read_text())
        assert built['passed'] and built['source_pins_unchanged']
        pins.update(json.loads((out/'media/started.json').read_text())['pins'])
        def run(seed):
            work=out/seed;work.mkdir()
            disk=out/'media'/seed/'coremark.img'
            before=builder.sha(disk)
            argv=[qemu,'-machine','pc','-accel','tcg','-cpu','pentium','-m','16',
                # This is fresh, private media. The pinned IDE model rejects
                # readonly=on; the post-run hash still rejects guest writes.
                '-drive',f'file={disk},format=raw,if=ide','-boot','c',
                '-display','none','-serial','none','-monitor','none','-no-reboot',
                '-no-shutdown','-debugcon',f'file:{work}/console.log',
                '-global','isa-debugcon.iobase=0xe9',
                '-device','isa-debug-exit,iobase=0xf4,iosize=0x04']
            command=builder.command(argv,work/'native.log',seconds=240,allowed=(33,))
            assert builder.sha(disk)==before
            return dict(seed=seed,command=command,disk_sha256=before,
                **grade_reference((work/'console.log').read_text(),seed,args.iterations))
        with ThreadPoolExecutor(max_workers=2) as pool:
            rows=list(pool.map(run,('performance','validation')))
    except Exception as exc: errors.append(repr(exc))
    stable=all(builder.sha(p)==h for p,h in pins.items())
    events={k:int(v) for k,v in (s.split() for s in (group/'memory.events').read_text().splitlines())}
    result=dict(passed=not errors and stable and len(rows)==2 and
        not events['oom'] and not events['oom_kill'],
        errors=errors,rows=rows,pins_unchanged=stable,pins=pins,
        seconds=time.monotonic()-start,memory_peak=int((group/'memory.peak').read_text()),
        memory_events=events,physical_board=False,standard_suite=False,gameplay_ipc=None,
        artifacts={str(p):builder.sha(p) for p in out.rglob('*') if p.is_file()})
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','artifacts')}))
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
