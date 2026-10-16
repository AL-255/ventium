"""Validate the cold input probe with real keyboard events on pinned QEMU.

This checks the diagnostic guest and its negative witness, not Ventium RTL.
No register/memory writes, snapshots, guest patches or QEMU timing scores.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import time

from build_pc_input_probe import REPO,sha


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--images',type=Path,required=True);ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args();scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    source=a.images.resolve(strict=True);out=a.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>4*1024**3
    assert out.is_relative_to(scratch) and out!=scratch and not out.exists()
    assert os.sched_getaffinity(0)=={16,17}
    group=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((group/'memory.max').read_text())<=1024**3
    assert (group/'memory.swap.max').read_text().strip()=='0'
    qroot=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu'
    qemu=(qroot/'build-sys/qemu-system-i386').resolve(strict=True)
    built=json.loads((source/'built.json').read_text())
    assert built['built'] and built['pins_unchanged'] and not built['executed']
    pins=dict(built['pins'])
    for p in (Path(__file__),qemu,qroot/'qapi/ui.json',source/'built.json'):
        pins[str(p.resolve())]=sha(p)
    # Pin BIOS/option-ROM search inputs used by this exact QEMU build.
    bios=qroot/'pc-bios'
    for p in bios.iterdir():
        if p.is_file():pins[str(p.resolve())]=sha(p)
    for row in built['rows']:
        assert sha(row['image'])==row['sha256'];pins[row['image']]=row['sha256']
    assert all(sha(p)==h for p,h in pins.items())
    out.mkdir()
    def save(p,d):
        with p.open('x') as f:json.dump(d,f,indent=2)
    save(out/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],rtl_execution=False))
    def case(spec):
        raw,wrong,cpu=spec;name=f'raw{raw}'+('-wrong-key' if wrong else '-positive')
        work=out/name;work.mkdir(mode=0o700)
        disk=work/'input.img';shutil.copyfile(source/f'raw{raw}'/'input.img',disk)
        debug=work/'debug.log'
        argv=['/usr/bin/taskset','-c',str(cpu),str(qemu),'-L',str(bios),'-machine','pc',
            '-accel','tcg','-cpu','pentium','-m','16','-drive',f'file={disk},format=raw,if=ide',
            '-boot','c','-display','none','-serial','none','-monitor','none','-qmp','stdio',
            '-no-reboot','-no-shutdown','-debugcon',f'file:{debug}',
            '-global','isa-debugcon.iobase=0xe9','-device','isa-debug-exit,iobase=0xf4,iosize=0x04']
        begin=time.monotonic();error=None;pending=bytearray();serial=0;observed={}
        with (work/'stderr.log').open('x') as stderr,(work/'qmp.jsonl').open('x') as qlog:
            child=subprocess.Popen(argv,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,start_new_session=True)
            def recv():
                limit=time.monotonic()+5
                while b'\n' not in pending:
                    assert time.monotonic()<limit,'QMP receive timeout'
                    if not select.select([child.stdout],[],[],.1)[0]:continue
                    data=os.read(child.stdout.fileno(),65536);assert data,'QMP EOF'
                    pending.extend(data);assert len(pending)<1024**2
                line,_,rest=pending.partition(b'\n');pending[:]=rest
                value=json.loads(line);qlog.write(json.dumps(dict(direction='receive',value=value))+'\n');qlog.flush()
                return value
            def command(execute,arguments=None):
                nonlocal serial
                serial+=1;value=dict(execute=execute,id=serial)
                if arguments is not None:value['arguments']=arguments
                qlog.write(json.dumps(dict(direction='send',value=value))+'\n');qlog.flush()
                child.stdin.write((json.dumps(value)+'\n').encode());child.stdin.flush()
                for _ in range(20):
                    response=recv()
                    if response.get('id')==serial:
                        assert 'return' in response and 'error' not in response,response
                        return
                raise RuntimeError('QMP reply missing')
            try:
                deadline=begin+5
                while Path('/proc',str(child.pid),'exe').resolve()!=qemu:
                    assert child.poll() is None and time.monotonic()<deadline
                    time.sleep(.01)
                assert os.sched_getaffinity(child.pid)=={cpu}
                observed=dict(pid=child.pid,affinity=sorted(os.sched_getaffinity(child.pid)),
                    exe=str(Path('/proc',str(child.pid),'exe').resolve()),
                    cgroup=Path('/proc',str(child.pid),'cgroup').read_text())
                assert observed['cgroup']==Path('/proc/self/cgroup').read_text()
                assert 'QMP' in recv();command('qmp_capabilities')
                while not debug.exists() or f'UI-PROBE-READY raw={raw}\n' not in debug.read_text():
                    assert child.poll() is None and time.monotonic()-begin<15,'guest readiness failed'
                    time.sleep(.01)
                # Explicit make/reverse-break order matches the ordinary-wire
                # input host. The wrong Esc/Tab event is a required red witness.
                second='tab' if wrong else 'esc'
                events=[dict(type='key',data=dict(down=down,key=dict(type='qcode',data=key)))
                        for key,down in [('ctrl',True),(second,True),(second,False),('ctrl',False),('ret',True),('ret',False)]]
                command('input-send-event',dict(events=events))
                code=child.wait(timeout=15)
                text=debug.read_text()
                assert code==(35 if wrong else 33),(code,text)
                assert text.count(f'UI-PROBE-READY raw={raw}\n')==1
                assert text.count('UI-PROBE-FAIL\n')==int(wrong)
                assert text.count(f'UI-PROBE-PASS raw={raw}\n')==int(not wrong)
                assert sha(disk)==sha(source/f'raw{raw}'/'input.img')
            except Exception as exc:error=repr(exc)
            finally:
                if child.poll() is None:
                    os.killpg(child.pid,signal.SIGTERM)
                    try:child.wait(timeout=3)
                    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
                else:child.wait()
                child.stdin.close();child.stdout.close()
        result=dict(case=name,passed=error is None,error=error,argv=argv,native_exit=child.returncode,
            observed=observed,actual_wait=True,proc_gone=not Path('/proc',str(child.pid)).exists(),
            seconds=time.monotonic()-begin,expected_wrong_key=wrong,
            artifacts={str(p):sha(p) for p in work.iterdir() if p.is_file()},rtl_execution=False)
        save(work/'closed.json',result);return result
    with ThreadPoolExecutor(max_workers=2) as pool:rows=list(pool.map(case,[(0,False,16),(1,False,17),(0,True,16)]))
    stable=all(sha(p)==h for p,h in pins.items())
    events={k:int(v) for k,v in (s.split() for s in (group/'memory.events').read_text().splitlines())}
    result=dict(passed=stable and all(r['passed'] and r['proc_gone'] for r in rows)
        and not any(events[k] for k in ('oom','oom_kill','oom_group_kill')),rows=rows,pins_unchanged=stable,
        memory_events=events,memory_peak=int((group/'memory.peak').read_text()),
        rtl_execution=False,standard_suite=False,gameplay_ipc=None)
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}))
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
